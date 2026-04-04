// GeoIP2-zig - MIT License
// MMDB parser - main API for IP geolocation lookups

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

// Import submodules
const mmdb_metadata = @import("metadata.zig");
const mmdb_data_reader = @import("data_reader.zig");
const mmdb_data_writer = @import("data_writer.zig");
const Metadata = mmdb_metadata.Metadata;

/// Magic string that marks the end of the data section
/// This is used to locate the metadata section in the MMDB file
const separator = "\xab\xcd\xefMaxMind.com";

/// MMDBFile provides the main API for loading and querying the MaxMind database.
/// It handles the binary trie search algorithm for IP lookups.
pub const MMDBFile = struct {
    /// Raw MMDB file data (embedded at compile time)
    data: []const u8,
    /// Offset where metadata section starts
    metadata_offset: usize,
    /// Offset where the data section starts (after trie nodes)
    nodes_offset: usize,
    /// Parsed metadata
    metadata: Metadata,
    /// Enable runtime assertions for debugging
    enable_assertions: bool = false,
    /// Allocator for temporary memory
    allocator: Allocator,

    /// Initialize an MMDBFile from raw binary data.
    /// This locates the metadata section, parses it, and prepares for lookups.
    pub fn init(data: []const u8, alloc: Allocator, enable_assertions: bool) !MMDBFile {
        // Find where metadata starts by looking for the magic separator
        const metadata_offset = try locateMetadataOffset(data);

        // Create a data reader at the metadata position
        const data_reader = mmdb_data_reader.dataReader(data, metadata_offset, enable_assertions, undefined);

        // Parse the metadata
        var metadata_reader = mmdb_metadata.metadataReader(data_reader);
        var metadata = Metadata.init(alloc);
        try metadata_reader.read(&metadata);

        // Validate required fields
        if (metadata.record_size == null or metadata.node_count == null) {
            return error.InvalidFormat;
        }

        // Calculate where the data section starts
        // Each node has 2 records, each record is record_size/8 bytes
        const nodes_offset = (((metadata.record_size orelse 0) * 2) / 8) * (metadata.node_count orelse 0);

        // Verify the database format (last 16 bytes of trie should be zeros)
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

    /// Free all allocated memory
    pub fn deinit(self: *MMDBFile) void {
        self.metadata.deinit();
    }

    /// Find the metadata section by searching backward from the end
    /// The MMDB format has metadata at the end, preceded by the magic string
    fn locateMetadataOffset(data: []const u8) !usize {
        if (data.len < 128 * 1024) return error.InvalidFormat;
        const max_header_size = 128 * 1024;
        const haystack = data[data.len - max_header_size ..];
        const last_index = std.mem.lastIndexOf(u8, haystack, separator);
        if (last_index) |li| {
            return (data.len - max_header_size) + li + separator.len;
        } else return error.InvalidFormat;
    }

    /// Print metadata as JSON to the provided writer
    pub fn print(self: MMDBFile, writer: *std.Io.Writer) !void {
        var metadata_writer = mmdb_metadata.metadataWriter(self.metadata);
        var json_stringify: json.Stringify = .{
            .writer = writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try json_stringify.beginObject();
        {
            try json_stringify.objectField("metadata_offset");
            try json_stringify.write(self.metadata_offset);
            try json_stringify.objectField("nodes_offset");
            try json_stringify.write(self.nodes_offset);
            try json_stringify.objectField("metadata");
            try metadata_writer.writeJSON(&json_stringify);
        }
        try json_stringify.endObject();
    }

    /// Parse an IPv4 address string into 4 bytes.
    /// Returns error.InvalidFormat if the string is not a valid IPv4 address.
    pub fn parseIpV4(str: []const u8) ![4]u8 {
        const a = try std.Io.net.IpAddress.parseIp4(str, 0);
        const b = std.mem.asBytes(&a.ip4.bytes);
        return b.*;
    }

    /// Parse an IPv6 address string into 16 bytes.
    /// Returns error.InvalidFormat if the string is not a valid IPv6 address.
    pub fn parseIpV6(str: []const u8) ![16]u8 {
        const a = try std.Io.net.IpAddress.parseIp6(str, 0);
        return a.ip6.bytes;
    }

    /// Look up an IPv4 address and write JSON to the provided writer.
    /// IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d).
    pub fn lookupIpV4(self: MMDBFile, address: [4]u8, writer: anytype) !void {
        try lookupIpV6(self, [16]u8{
            0x00,       0x00,       0x00,
            0x00,       0x00,       0x00,
            0x00,       0x00,       0x00,
            0x00,       0xff,       0xff,
            address[0], address[1], address[2],
            address[3],
        }, writer);
    }

    /// Check if an IP address has data in the database (fast probe).
    /// Returns true if data exists, false otherwise.
    pub fn lookupIpV6Probe(self: MMDBFile, address: [16]u8) bool {
        return self.locateDataNode(address) != null;
    }

    /// Look up an IPv6 address and write JSON to the provided writer.
    /// Uses a binary trie (Patricia trie) search algorithm.
    pub fn lookupIpV6(self: MMDBFile, address: [16]u8, writer: anytype) !void {
        const offset = self.locateDataNode(address);
        if (offset) |o| {
            _ = try self.writeData(o, writer);
        } else {
            return error.NoData;
        }
    }

    /// Locate the data node for a given IP address.
    /// Traverses the Patricia trie bit by bit, following left/right
    /// records based on each bit of the address.
    pub fn locateDataNode(self: MMDBFile, address: [16]u8) ?usize {
        // Calculate how many bytes each record takes
        const record_size_in_bytes = (((self.metadata.record_size orelse 0) * 2) / 8);
        var node_offset: usize = 0;

        // For 28-bit records, we use the "search tree" approach
        const bytes_per_offset: usize = self.metadata.record_size.? / 8;
        const use_nibble = self.metadata.record_size.? % 8 == 4;

        // Traverse the trie, one bit at a time (max 128 bits for IPv6)
        for (0..128) |bit_idx| {
            const byte_idx: usize = bit_idx / 8;
            const bit_in_byte: u3 = @truncate(7 - (bit_idx % 8));
            const bit = (address[byte_idx] >> bit_in_byte) & 1;

            // Get either the left (0) or right (1) record at this node
            const record = if (bit == 0)
                left_record(self.data, node_offset, bytes_per_offset, use_nibble)
            else
                right_record(self.data, node_offset, bytes_per_offset, use_nibble);

            // Check what this record points to
            if (record == self.metadata.node_count.?) {
                // No data at this prefix
                return null;
            } else if (record > self.metadata.node_count.?) {
                // This is a data pointer - calculate actual data offset
                return self.nodes_offset - 16 + (record - self.metadata.node_count.?);
            }

            // Move to the next node
            node_offset = record * record_size_in_bytes;
        }

        return null;
    }

    /// Extract the left record from a trie node.
    /// The left record contains the "0" bit path.
    fn left_record(data: []const u8, offset: usize, bytes_per_offset: usize, use_nibble: bool) usize {
        var result: usize = 0;
        // If using nibble mode, the left record is in the upper 4 bits
        if (use_nibble) {
            result = data[offset + bytes_per_offset] & 0b11110000;
            result >>= 4;
        }
        // Read the remaining bytes
        for (0..bytes_per_offset) |i| {
            result <<= 8;
            result |= data[offset + i];
        }
        return result;
    }

    /// Extract the right record from a trie node.
    /// The right record contains the "1" bit path.
    fn right_record(data: []const u8, offset: usize, bytes_per_offset: usize, use_nibble: bool) usize {
        var result: usize = 0;
        // If using nibble mode, the right record is in the lower 4 bits
        if (use_nibble) {
            result = data[offset + bytes_per_offset] & 0b1111;
        }
        var right_offset = bytes_per_offset;
        if (use_nibble) right_offset += 1;
        // Read the remaining bytes
        for (0..bytes_per_offset) |i| {
            result <<= 8;
            result |= data[offset + right_offset + i];
        }
        return result;
    }

    /// Write data at a given offset to the JSON writer.
    /// This is called when we've found the data node for an IP.
    pub fn writeData(self: MMDBFile, offset: usize, writer: anytype) !usize {
        // Validate offset is within the data section
        if (offset < self.nodes_offset or offset >= (self.metadata_offset - separator.len)) {
            return error.InvalidArgument;
        }

        // Create a reader at the data location
        var data_reader = mmdb_data_reader.dataReader(self.data, offset, self.enable_assertions, self.nodes_offset);

        // Create JSON serializer
        var json_stringify: json.Stringify = .{
            .writer = writer,
            .options = .{ .whitespace = .indent_2 },
        };

        // Write the data to JSON
        const data_writer = mmdb_data_writer.dataWriter(self.nodes_offset);
        try data_writer.writeObject(&data_reader, &json_stringify);

        return data_reader.offset;
    }
};

// Verify all submodules compile
test {
    _ = mmdb_metadata;
    _ = mmdb_data_reader;
    _ = mmdb_data_writer;
}
