const std = @import("std");
const StringStringHashMap = std.StringHashMapUnmanaged([]const u8);
const StringArrayList = std.ArrayListUnmanaged([]const u8);
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const mmdb_data_reader = @import("data_reader.zig");
const DataReader = mmdb_data_reader.DataReader;

/// A container for:
/// {
///  "binary_format_major_version": 2,
///  "binary_format_minor_version": 0,
///  "build_epoch": 1725363976,
///  "database_type": "GeoLite2-City",
///  "description": {
///    "en": "GeoLite2City database"
///  },
///  "ip_version": 6,
///  "languages": [
///    "de",
///    "en",
///    "es",
///    "fr",
///    "ja",
///    "pt-BR",
///    "ru",
///    "zh-CN"
///  ],
///  "node_count": 4252760,
///  "record_size": 28
///}
pub const Metadata = struct {
    allocator: Allocator,

    binary_format_major_version: ?u16 = null,
    binary_format_minor_version: ?u16 = null,
    build_epoch: ?u64 = null,
    database_type: ?[]const u8 = null,
    description: StringStringHashMap = .{},
    ip_version: ?u16 = null,
    languages: StringArrayList = .{},
    node_count: ?u32 = null,
    record_size: ?u16 = null,

    pub fn init(alloc: Allocator) Metadata {
        return .{
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Metadata) void {
        self.languages.deinit(self.allocator);
        self.description.deinit(self.allocator);
    }

    fn addDescription(self: *Metadata, key: []const u8, value: []const u8) !void {
        try self.description.put(self.allocator, key, value);
    }

    fn appendLanguage(self: *Metadata, lang: []const u8) !void {
        try self.languages.append(self.allocator, lang);
    }
};

pub fn metadataReader(reader: DataReader) MetadataReader {
    return .{
        .reader = reader,
    };
}

pub const MetadataReader = struct {
    reader: DataReader,

    pub fn read(self: *MetadataReader, metadata: *Metadata) !void {
        try self.reader.assertNextType(.map);

        const len = try self.reader.readPayloadSize();
        for (0..len) |_| {
            // Decode key. According to the spec they're always strings.
            const key = try self.reader.readString();
            // Decode the value depending on the value of the key.
            if (eql(u8, key, "binary_format_major_version")) {
                metadata.binary_format_major_version = try self.reader.readUint16();
            } else if (eql(u8, key, "binary_format_minor_version")) {
                metadata.binary_format_minor_version = try self.reader.readUint16();
            } else if (eql(u8, key, "build_epoch")) {
                metadata.build_epoch = try self.reader.readUint64();
            } else if (eql(u8, key, "database_type")) {
                metadata.database_type = try self.reader.readString();
            } else if (eql(u8, key, "description")) {
                try self.readDescriptionMap(metadata);
            } else if (eql(u8, key, "ip_version")) {
                metadata.ip_version = try self.reader.readUint16();
            } else if (eql(u8, key, "languages")) {
                try self.readLanguagesArray(metadata);
            } else if (eql(u8, key, "node_count")) {
                metadata.node_count = try self.reader.readUint32();
            } else if (eql(u8, key, "record_size")) {
                metadata.record_size = try self.reader.readUint16();
            } else unreachable;
        }
    }

    fn readDescriptionMap(self: *MetadataReader, metadata: *Metadata) !void {
        try self.reader.assertNextType(.map);

        const len = try self.reader.readPayloadSize();
        for (0..len) |_| {
            const key = try self.reader.readString();
            const value = try self.reader.readString();
            try metadata.addDescription(key, value);
        }
    }

    fn readLanguagesArray(self: *MetadataReader, metadata: *Metadata) !void {
        try self.reader.assertNextType(.array);

        const len = try self.reader.readPayloadSize();
        for (0..len) |_| {
            const lang = try self.reader.readString();
            try metadata.appendLanguage(lang);
        }
    }
};

////////////////////////////////////////////////////////////////////////////////

pub fn metadataWriter(metadata: Metadata) MetadataWriter {
    return .{
        .metadata = metadata,
    };
}

const MetadataWriter = struct {
    metadata: Metadata,

    /// writer is assumed to be a std.json.WriteStream.
    pub fn writeJSON(self: MetadataWriter, writer: anytype) !void {
        try writer.beginObject();
        {
            try writer.objectField("binary_format_major_version");
            try writer.write(self.metadata.binary_format_major_version);
            try writer.objectField("binary_format_minor_version");
            try writer.write(self.metadata.binary_format_minor_version);
            try writer.objectField("build_epoch");
            try writer.write(self.metadata.build_epoch);
            try writer.objectField("database_type");
            try writer.write(self.metadata.database_type);
            try writer.objectField("description");
            try writer.beginObject();
            {
                var it = self.metadata.description.iterator();
                while (it.next()) |e| {
                    try writer.objectField(e.key_ptr.*);
                    try writer.write(e.value_ptr.*);
                }
            }
            try writer.endObject();
            try writer.objectField("ip_version");
            try writer.write(self.metadata.ip_version);
            try writer.objectField("languages");
            try writer.beginArray();
            {
                for (self.metadata.languages.items) |lang| {
                    try writer.write(lang);
                }
            }
            try writer.endArray();
            try writer.objectField("node_count");
            try writer.write(self.metadata.node_count);
            try writer.objectField("record_size");
            try writer.write(self.metadata.record_size);
        }
        try writer.endObject();
    }
};

////////////////////////////////////////////////////////////////////////////////

const expectEqualStrings = std.testing.expectEqualStrings;

test {
    _ = mmdb_data_reader;
}

test "serialize to JSON" {
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    metadata.binary_format_major_version = 2;
    metadata.binary_format_minor_version = 0;
    metadata.build_epoch = 1725363976;
    metadata.database_type = "GeoLite2-City";
    metadata.ip_version = 6;
    metadata.node_count = 4252760;
    metadata.record_size = 28;

    try metadata.addDescription("en", "GeoLite2City database");
    for ([_][]const u8{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" }) |lang| {
        try metadata.appendLanguage(lang);
    }

    const writer = metadataWriter(metadata);
    var string = std.ArrayList(u8).init(std.testing.allocator);
    defer string.deinit();

    var json_stream = std.json.writeStream(string.writer(), .{
        .emit_null_optional_fields = true,
        .whitespace = .indent_2,
    });
    try writer.writeJSON(&json_stream);

    const expected =
        \\{
        \\  "binary_format_major_version": 2,
        \\  "binary_format_minor_version": 0,
        \\  "build_epoch": 1725363976,
        \\  "database_type": "GeoLite2-City",
        \\  "description": {
        \\    "en": "GeoLite2City database"
        \\  },
        \\  "ip_version": 6,
        \\  "languages": [
        \\    "de",
        \\    "en",
        \\    "es",
        \\    "fr",
        \\    "ja",
        \\    "pt-BR",
        \\    "ru",
        \\    "zh-CN"
        \\  ],
        \\  "node_count": 4252760,
        \\  "record_size": 28
        \\}
    ;
    try expectEqualStrings(expected, string.items);
}
