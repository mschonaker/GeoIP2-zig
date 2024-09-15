const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const io = std.io;
const fs = std.fs;
const json = std.json;

const mmdb_metadata = @import("metadata.zig");
const mmdb_data_reader = @import("data_reader.zig");
const mmdb_data_writer = @import("data_writer.zig");
const Metadata = mmdb_metadata.Metadata;

const separator = "\xab\xcd\xefMaxMind.com";

pub const MMDBFile = struct {
    // For the metadata structures to be held. They belong to the file.
    // Other loaded data by the query shouldn't be stored here.
    data: []const u8,
    metadata_offset: usize,
    nodes_offset: usize,
    metadata: Metadata,
    enable_assertions: bool,
    allocator: Allocator,

    pub fn init(data: []const u8, alloc: Allocator, enable_assertions: bool) !MMDBFile {
        const metadata_offset = try locateMetadataOffset(data);
        const data_reader = mmdb_data_reader.dataReader(data, metadata_offset, enable_assertions, undefined);
        var metadata_reader = mmdb_metadata.metadataReader(data_reader);
        var metadata = Metadata.init(alloc);
        try metadata_reader.read(&metadata);

        if (metadata.record_size == null or metadata.node_count == null) {
            return error.InvalidFormat;
        }

        const nodes_offset = (((metadata.record_size orelse 0) * 2) / 8) * (metadata.node_count orelse 0);
        if (enable_assertions) {
            for (0..16) |i| {
                if (data[nodes_offset + i] != 0) return error.InvalidFormat;
            }
        }

        return .{
            .data = data,
            .metadata_offset = metadata_offset,
            .nodes_offset = nodes_offset + 16,
            .metadata = metadata,
            .enable_assertions = enable_assertions,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *MMDBFile) void {
        self.metadata.deinit();
    }

    fn locateMetadataOffset(data: []const u8) !usize {
        if (data.len < 128 * 1024) return error.InvalidFormat;
        const max_header_size = 128 * 1024;
        const haystack = data[data.len - max_header_size ..];
        const last_index = std.mem.lastIndexOf(u8, haystack, separator);
        if (last_index) |li| {
            return (data.len - max_header_size) + li + separator.len;
        } else return error.InvalidFormat;
    }

    pub fn print(self: MMDBFile, writer: anytype) !void {
        var metadata_writer = mmdb_metadata.metadataWriter(self.metadata);
        var json_stream = json.writeStream(writer, .{
            .emit_null_optional_fields = true,
            .whitespace = .indent_2,
        });
        try json_stream.beginObject();
        {
            try json_stream.objectField("metadata_offset");
            try json_stream.write(self.metadata_offset);
            try json_stream.objectField("nodes_offset");
            try json_stream.write(self.nodes_offset);
            try json_stream.objectField("metadata");
            try metadata_writer.writeJSON(&json_stream);
        }
        try json_stream.endObject();
    }

    pub fn resolveIpV4(self: MMDBFile, address: [4]u8, writer: anytype) !void {
        try resolveIpV6(self, [16]u8{
            0x00,       0x00,
            0x00,       0x00,
            0x00,       0x00,
            0x00,       0x00,
            0x00,       0x00,
            0xff,       0xff,
            address[0], address[1],
            address[2], address[3],
        }, writer);
    }

    pub fn resolveIpV6(self: MMDBFile, address: [16]u8, writer: anytype) !void {
        const offset = self.locateDataNode(address);
        if (offset) |o| {
            _ = try self.writeData(o, writer);
        } else {
            return error.NoData;
        }
    }

    pub fn locateDataNode(self: MMDBFile, address: [16]u8) ?usize {
        const record_size_in_bytes = (((self.metadata.record_size orelse 0) * 2) / 8);

        var fbs = io.fixedBufferStream(&address);
        var br = io.bitReader(.big, fbs.reader());

        var out_bits: usize = undefined;
        var node_offset: usize = 0;

        const bytes_per_offset: usize = self.metadata.record_size.? / 8;
        const use_nibble = self.metadata.record_size.? % 8 == 4;

        for (0..128) |_| {
            const bit = br.readBits(u1, 1, &out_bits) catch unreachable;

            const record = if (bit == 0)
                left_record(self.data, node_offset, bytes_per_offset, use_nibble)
            else
                right_record(self.data, node_offset, bytes_per_offset, use_nibble);

            if (record == self.metadata.node_count.?) {
                return null;
            } else if (record > self.metadata.node_count.?) {
                return self.nodes_offset - 16 + (record - self.metadata.node_count.?);
            }

            node_offset = record * record_size_in_bytes;
        }

        return null;
    }

    fn left_record(data: []const u8, offset: usize, bytes_per_offset: usize, use_nibble: bool) usize {
        // std.debug.print("bytes: {b:0>8}\n", .{data[offset .. offset + bytes_per_offset * 2 + 1]});

        var result: usize = 0;
        if (use_nibble) {
            result = data[offset + bytes_per_offset] & 0b11110000;
            result >>= 4;
        }

        for (0..bytes_per_offset) |i| {
            result <<= 8;
            result |= data[offset + i];
        }

        // std.debug.print("left record: {d}\n", .{result});
        return result;
    }

    fn right_record(data: []const u8, offset: usize, bytes_per_offset: usize, use_nibble: bool) usize {
        var result: usize = 0;
        if (use_nibble) {
            result = data[offset + bytes_per_offset] & 0b1111;
        }

        var right_offset = bytes_per_offset;
        if (use_nibble) right_offset += 1;

        for (0..bytes_per_offset) |i| {
            result <<= 8;
            result |= data[offset + right_offset + i];
        }

        return result;
    }

    pub fn writeData(self: MMDBFile, offset: usize, writer: anytype) !usize {
        if (offset < self.nodes_offset or offset >= (self.metadata_offset - separator.len)) {
            std.debug.print("offset {d} is between {d} and {d}\n", .{ offset, self.nodes_offset, self.metadata_offset - separator.len });
            return error.InvalidArgument;
        }

        var data_reader = mmdb_data_reader.dataReader(
            self.data,
            offset,
            self.enable_assertions,
            self.nodes_offset,
        );
        var json_stream = json.writeStream(writer, .{
            .emit_null_optional_fields = true,
            .whitespace = .indent_2,
        });
        const data_writer = mmdb_data_writer.dataWriter(self.nodes_offset);
        try data_writer.writeObject(&data_reader, &json_stream);
        return data_reader.offset;
    }
};

////////////////////////////////////////////////////////////////////////////////

test {
    _ = mmdb_metadata;
    _ = mmdb_data_reader;
    _ = mmdb_data_writer;
}
