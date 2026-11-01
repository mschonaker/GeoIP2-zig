// GeoIP2-zig
// MMDB parser - main API for IP geolocation lookups.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

// Import submodules.
const DataReader = @import("data_reader.zig").DataReader;
const data_writer = @import("data_writer.zig");
const Metadata = @import("metadata.zig").Metadata;

pub const Projection = @import("projection.zig").Projection;

/// Magic string that marks the end of the data section
/// This is used to locate the metadata section in the MMDB file.
const separator = "\xab\xcd\xefMaxMind.com";

/// Format checks are debug checks. They compile out in release builds.
const enable_assertions = @import("builtin").mode == .debug;

/// MMDBFile provides the main API for loading and querying the MaxMind database.
/// It handles the binary trie search algorithm for IP lookups.
pub const MMDBFile = struct {
    /// Raw MMDB file data (embedded at compile time).
    data: []const u8,
    /// Offset where metadata section starts.
    metadata_offset: usize,
    /// Offset where the data section starts (after trie nodes).
    nodes_offset: usize,
    /// Parsed metadata.
    metadata: Metadata,
    /// Allocator for temporary memory.
    allocator: Allocator,

    /// Initialize an MMDBFile from raw binary data.
    /// This locates the metadata section, parses it, and prepares for lookups.
    pub fn init(data: []const u8, alloc: Allocator) !MMDBFile {
        // Find where metadata starts by looking for the magic separator.
        const metadata_offset = try locateMetadataOffset(data);

        // Create a data reader at the metadata position.
        var data_reader = DataReader.init(data, metadata_offset, undefined);

        // Parse the metadata.
        var metadata = Metadata.init(alloc);
        errdefer metadata.deinit();
        try metadata.read(&data_reader);

        // Validate required fields.
        const record_size = metadata.record_size orelse return error.InvalidFormat;
        const node_count = metadata.node_count orelse return error.InvalidFormat;
        if (record_size != 24 and record_size != 28 and record_size != 32) return error.InvalidFormat;

        // Calculate where the data section starts
        // Each node has 2 records, each record is record_size/8 bytes.
        const node_bytes = std.math.mul(usize, (record_size * 2) / 8, node_count) catch
            return error.InvalidFormat;
        const trie_end = std.math.add(usize, node_bytes, 16) catch return error.InvalidFormat;
        if (trie_end > metadata_offset) return error.InvalidFormat;
        if (trie_end > data.len) return error.InvalidFormat;

        // Verify the database format (last 16 bytes of trie should be zeros).
        if (enable_assertions) {
            for (0..16) |i| {
                if (data[node_bytes + i] != 0) return error.InvalidFormat;
            }
        }

        return .{
            .data = data,
            .metadata_offset = metadata_offset,
            .nodes_offset = trie_end,
            .metadata = metadata,
            .allocator = alloc,
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *MMDBFile) void {
        self.metadata.deinit();
    }

    /// Find the metadata section by searching backward from the end
    /// The MMDB format has metadata at the end, preceded by the magic string.
    fn locateMetadataOffset(data: []const u8) !usize {
        if (data.len < 128 * 1024) return error.InvalidFormat;
        const max_header_size = 128 * 1024;
        const haystack = data[data.len - max_header_size ..];
        const last_index = std.mem.lastIndexOf(u8, haystack, separator);
        if (last_index) |li| {
            return (data.len - max_header_size) + li + separator.len;
        } else return error.InvalidFormat;
    }

    /// Print metadata as JSON to the provided writer.
    pub fn print(self: *const MMDBFile, writer: *std.Io.Writer) !void {
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
            try self.metadata.writeJSON(&json_stringify);
        }
        try json_stringify.endObject();
    }

    /// Check if an IP address has data in the database (fast probe).
    /// Returns true if data exists, false otherwise.
    pub fn lookupIpV6Probe(self: *const MMDBFile, address: [16]u8) bool {
        return self.locateDataNode(address) != null;
    }

    /// Look up an IPv6 address and write JSON to the provided writer.
    /// Uses a binary trie (Patricia trie) search algorithm.
    /// A non-null `projection` serializes only the requested fields.
    pub fn lookupIpV6(
        self: *const MMDBFile,
        address: [16]u8,
        writer: anytype,
        projection: ?*const Projection,
    ) !void {
        const offset = self.locateDataNode(address) orelse return error.NoData;
        try self.writeData(offset, writer, projection);
    }

    /// Locate the data node for a given IP address.
    /// Traverses the Patricia trie bit by bit, following left/right
    /// records based on each bit of the address.
    pub fn locateDataNode(self: *const MMDBFile, address: [16]u8) ?usize {
        const record_size = self.metadata.record_size orelse return null;
        const node_count = self.metadata.node_count orelse return null;
        // Calculate how many bytes each record takes.
        const record_size_in_bytes = (record_size * 2) / 8;
        var node_offset: usize = 0;

        // For 28-bit records, we use the "search tree" approach.
        const bytes_per_offset: usize = record_size / 8;
        const use_nibble = record_size % 8 == 4;

        // Traverse the trie, one bit at a time (max 128 bits for IPv6).
        for (0..128) |bit_idx| {
            // The node must fit inside the data.
            if (node_offset > self.data.len) return null;
            if (record_size_in_bytes > self.data.len - node_offset) return null;

            const byte_idx: usize = bit_idx / 8;
            const bit_in_byte: u3 = @truncate(7 - (bit_idx % 8));
            const bit = (address[byte_idx] >> bit_in_byte) & 1;

            // Get either the left (0) or right (1) record at this node.
            const record = if (bit == 0)
                left_record(self.data, node_offset, bytes_per_offset, use_nibble)
            else
                right_record(self.data, node_offset, bytes_per_offset, use_nibble);

            // No data at this prefix.
            if (record == node_count) return null;
            // This is a data pointer - calculate actual data offset.
            if (record > node_count) return self.nodes_offset - 16 + (record - node_count);

            // Move to the next node.
            node_offset = std.math.mul(usize, record, record_size_in_bytes) catch return null;
        }

        return null;
    }

    /// Extract the left record from a trie node.
    /// The left record contains the "0" bit path.
    fn left_record(data: []const u8, offset: usize, bytes_per_offset: usize, use_nibble: bool) usize {
        var result: usize = 0;
        // If using nibble mode, the left record is in the upper 4 bits.
        if (use_nibble) {
            result = data[offset + bytes_per_offset] & 0b11110000;
            result >>= 4;
        }
        // Read the remaining bytes.
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
        // If using nibble mode, the right record is in the lower 4 bits.
        if (use_nibble) result = data[offset + bytes_per_offset] & 0b1111;
        var right_offset = bytes_per_offset;
        if (use_nibble) right_offset += 1;
        // Read the remaining bytes.
        for (0..bytes_per_offset) |i| {
            result <<= 8;
            result |= data[offset + right_offset + i];
        }
        return result;
    }

    /// Write data at a given offset to the JSON writer.
    /// This is called when we've found the data node for an IP.
    pub fn writeData(
        self: *const MMDBFile,
        offset: usize,
        writer: anytype,
        projection: ?*const Projection,
    ) !void {
        // Validate offset is within the data section.
        if (offset < self.nodes_offset or offset >= (self.metadata_offset - separator.len))
            return error.InvalidArgument;

        // Create a reader at the data location.
        var data_reader = DataReader.init(self.data, offset, self.nodes_offset);

        // Create JSON serializer.
        var json_stringify: json.Stringify = .{
            .writer = writer,
            .options = .{ .whitespace = .indent_2 },
        };

        // Write the data to JSON.
        if (projection) |proj| return data_writer.writeProjection(&data_reader, &json_stringify, proj);
        try data_writer.writeObject(&data_reader, &json_stringify);
    }
};

////////////////////////////////////////////////////////////////////////////////

test "init and deinit do not leak" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var file = try MMDBFile.init(@embedFile("corpus/real.mmdb"), allocator);
    file.deinit();

    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

test "init rejects a truncated database without leaking" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    const seed = @embedFile("corpus/real.mmdb");

    try std.testing.expectError(
        error.InvalidFormat,
        MMDBFile.init(seed[0 .. seed.len - 1], allocator),
    );

    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}
