// GeoIP2-zig
// MMDB metadata parser - reads and writes database metadata.

const std = @import("std");
const StringStringHashMap = std.StringHashMapUnmanaged([]const u8);
const StringArrayList = std.ArrayListUnmanaged([]const u8);
const Allocator = std.mem.Allocator;

/// Import the data reader for parsing binary metadata.
const DataReader = @import("data_reader.zig").DataReader;

/// Metadata holds all the information about the MaxMind database.
/// This includes version numbers, database type, supported languages,
/// node count for the trie, and record size.
pub const Metadata = struct {
    allocator: Allocator,

    /// Major version of the binary format (typically 2).
    binary_format_major_version: ?u16 = null,
    /// Minor version of the binary format (typically 0).
    binary_format_minor_version: ?u16 = null,
    /// Unix timestamp when the database was built.
    build_epoch: ?u64 = null,
    /// Type identifier (e.g., "GeoLite2-City").
    database_type: ?[]const u8 = null,
    /// Human-readable descriptions in various languages.
    description: StringStringHashMap = .{},
    /// IP version (4 or 6).
    ip_version: ?u16 = null,
    /// List of supported language codes.
    languages: StringArrayList = .empty,
    /// Number of nodes in the search trie.
    node_count: ?u32 = null,
    /// Size of each record in bits.
    record_size: ?u16 = null,

    /// Initialize metadata with an allocator.
    pub fn init(alloc: Allocator) Metadata {
        return .{ .allocator = alloc };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *Metadata) void {
        self.languages.deinit(self.allocator);
        self.description.deinit(self.allocator);
    }

    /// Metadata field names, as they appear in the database.
    const Field = enum {
        binary_format_major_version,
        binary_format_minor_version,
        build_epoch,
        database_type,
        description,
        ip_version,
        languages,
        node_count,
        record_size,
    };

    /// Read and parse all metadata fields from the database.
    pub fn read(self: *Metadata, reader: *DataReader) !void {
        // Metadata is always stored as a map at the start of the metadata section.
        try reader.assertNextType(.map);
        const len = try reader.readPayloadSize();

        // Iterate through each key-value pair in the metadata map.
        for (0..len) |_| {
            const key = try reader.readString();
            const field = std.meta.stringToEnum(Field, key) orelse return error.InvalidFormat;
            try self.readField(field, reader);
        }
    }

    /// Read the value for one metadata field.
    fn readField(self: *Metadata, field: Field, reader: *DataReader) !void {
        switch (field) {
            .binary_format_major_version => {
                self.binary_format_major_version = try reader.readUint16();
            },
            .binary_format_minor_version => {
                self.binary_format_minor_version = try reader.readUint16();
            },
            .build_epoch => self.build_epoch = try reader.readUint64(),
            .database_type => self.database_type = try reader.readString(),
            .description => try self.readDescriptionMap(reader),
            .ip_version => self.ip_version = try reader.readUint16(),
            .languages => try self.readLanguagesArray(reader),
            .node_count => self.node_count = try reader.readUint32(),
            .record_size => self.record_size = try reader.readUint16(),
        }
    }

    /// Read the description map (language code -> description).
    fn readDescriptionMap(self: *Metadata, reader: *DataReader) !void {
        try reader.assertNextType(.map);
        const len = try reader.readPayloadSize();
        for (0..len) |_| {
            const key = try reader.readString();
            const value = try reader.readString();
            try self.description.put(self.allocator, key, value);
        }
    }

    /// Read the list of supported languages.
    fn readLanguagesArray(self: *Metadata, reader: *DataReader) !void {
        try reader.assertNextType(.array);
        const len = try reader.readPayloadSize();
        for (0..len) |_| {
            const lang = try reader.readString();
            try self.languages.append(self.allocator, lang);
        }
    }

    /// Write metadata as JSON to the provided writer.
    pub fn writeJSON(self: *const Metadata, writer: anytype) !void {
        try writer.beginObject();
        {
            try writer.objectField("binary_format_major_version");
            try writer.write(self.binary_format_major_version);
            try writer.objectField("binary_format_minor_version");
            try writer.write(self.binary_format_minor_version);
            try writer.objectField("build_epoch");
            try writer.write(self.build_epoch);
            try writer.objectField("database_type");
            try writer.write(self.database_type);
            try writer.objectField("description");
            try writer.beginObject();
            {
                var it = self.description.iterator();
                while (it.next()) |e| {
                    try writer.objectField(e.key_ptr.*);
                    try writer.write(e.value_ptr.*);
                }
            }
            try writer.endObject();
            try writer.objectField("ip_version");
            try writer.write(self.ip_version);
            try writer.objectField("languages");
            try writer.beginArray();
            {
                for (self.languages.items) |lang| {
                    try writer.write(lang);
                }
            }
            try writer.endArray();
            try writer.objectField("node_count");
            try writer.write(self.node_count);
            try writer.objectField("record_size");
            try writer.write(self.record_size);
        }
        try writer.endObject();
    }
};

////////////////////////////////////////////////////////////////////////////////

/// Builds MMDB-encoded metadata for the tests.
const Builder = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn append(self: *Builder, bytes: []const u8) void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn byte(self: *Builder, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn appendString(self: *Builder, s: []const u8) void {
        self.byte(0x40 | @as(u8, @intCast(s.len)));
        self.append(s);
    }

    fn appendUint16(self: *Builder, v: u16) void {
        self.byte(0xA2);
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .big);
        self.append(&tmp);
    }

    fn appendUint32(self: *Builder, v: u32) void {
        self.byte(0xC4);
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .big);
        self.append(&tmp);
    }

    fn appendUint64(self: *Builder, v: u64) void {
        self.byte(0x08);
        self.byte(2);
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .big);
        self.append(&tmp);
    }
};

/// Encode a metadata map with every known field.
fn fullMetadata() Builder {
    var b: Builder = .{};
    b.byte(0xE0 | 9);
    b.appendString("binary_format_major_version");
    b.appendUint16(2);
    b.appendString("binary_format_minor_version");
    b.appendUint16(0);
    b.appendString("build_epoch");
    b.appendUint64(1_700_000_000);
    b.appendString("database_type");
    b.appendString("GeoLite2-City");
    b.appendString("description");
    b.byte(0xE1);
    b.appendString("en");
    b.appendString("GeoLite2 City Test");
    b.appendString("ip_version");
    b.appendUint16(6);
    b.appendString("languages");
    b.byte(0x02);
    b.byte(4);
    b.appendString("en");
    b.appendString("de");
    b.appendString("node_count");
    b.appendUint32(1234);
    b.appendString("record_size");
    b.appendUint16(24);
    return b;
}

test "read parses every field" {
    var builder = fullMetadata();
    var reader = DataReader.init(builder.buf[0..builder.len], 0, 0);
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    try metadata.read(&reader);

    try std.testing.expectEqual(@as(?u16, 2), metadata.binary_format_major_version);
    try std.testing.expectEqual(@as(?u16, 0), metadata.binary_format_minor_version);
    try std.testing.expectEqual(@as(?u64, 1_700_000_000), metadata.build_epoch);
    try std.testing.expectEqualStrings("GeoLite2-City", metadata.database_type.?);
    try std.testing.expectEqualStrings("GeoLite2 City Test", metadata.description.get("en").?);
    try std.testing.expectEqual(@as(?u16, 6), metadata.ip_version);
    try std.testing.expectEqual(2, metadata.languages.items.len);
    try std.testing.expectEqualStrings("en", metadata.languages.items[0]);
    try std.testing.expectEqualStrings("de", metadata.languages.items[1]);
    try std.testing.expectEqual(@as(?u32, 1234), metadata.node_count);
    try std.testing.expectEqual(@as(?u16, 24), metadata.record_size);
}

test "read rejects an unknown key" {
    var b: Builder = .{};
    b.byte(0xE0 | 1);
    b.appendString("unknown_field");
    b.appendUint16(1);

    var reader = DataReader.init(b.buf[0..b.len], 0, 0);
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    try std.testing.expectError(error.InvalidFormat, metadata.read(&reader));
}

test "writeJSON serializes every field" {
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();
    metadata.binary_format_major_version = 2;
    metadata.binary_format_minor_version = 0;
    metadata.build_epoch = 1_700_000_000;
    metadata.database_type = "GeoLite2-City";
    metadata.ip_version = 6;
    metadata.node_count = 1234;
    metadata.record_size = 24;
    try metadata.description.put(std.testing.allocator, "en", "GeoLite2 City Test");
    try metadata.languages.append(std.testing.allocator, "en");

    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var stringify: std.json.Stringify = .{ .writer = &w };
    try metadata.writeJSON(&stringify);

    try std.testing.expectEqualStrings(
        "{\"binary_format_major_version\":2,\"binary_format_minor_version\":0," ++
            "\"build_epoch\":1700000000,\"database_type\":\"GeoLite2-City\"," ++
            "\"description\":{\"en\":\"GeoLite2 City Test\"},\"ip_version\":6," ++
            "\"languages\":[\"en\"],\"node_count\":1234,\"record_size\":24}",
        out[0..w.end],
    );
}

test "deinit frees every allocation" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var metadata = Metadata.init(allocator);
    try metadata.description.put(allocator, "en", "GeoLite2 City Test");
    try metadata.languages.append(allocator, "en");
    metadata.deinit();

    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}
