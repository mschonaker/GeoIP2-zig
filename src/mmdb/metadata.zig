// GeoIP2-zig
// MMDB metadata parser - reads and writes database metadata

const std = @import("std");
const StringStringHashMap = std.StringHashMapUnmanaged([]const u8);
const StringArrayList = std.ArrayListUnmanaged([]const u8);
const Allocator = std.mem.Allocator;

/// Import the data reader for parsing binary metadata
const DataReader = @import("data_reader.zig").DataReader;

/// Metadata holds all the information about the MaxMind database.
/// This includes version numbers, database type, supported languages,
/// node count for the trie, and record size.
pub const Metadata = struct {
    allocator: Allocator,

    /// Major version of the binary format (typically 2)
    binary_format_major_version: ?u16 = null,
    /// Minor version of the binary format (typically 0)
    binary_format_minor_version: ?u16 = null,
    /// Unix timestamp when the database was built
    build_epoch: ?u64 = null,
    /// Type identifier (e.g., "GeoLite2-City")
    database_type: ?[]const u8 = null,
    /// Human-readable descriptions in various languages
    description: StringStringHashMap = .{},
    /// IP version (4 or 6)
    ip_version: ?u16 = null,
    /// List of supported language codes
    languages: StringArrayList = .{ .items = &.{}, .capacity = 0 },
    /// Number of nodes in the search trie
    node_count: ?u32 = null,
    /// Size of each record in bits
    record_size: ?u16 = null,

    /// Initialize metadata with an allocator
    pub fn init(alloc: Allocator) Metadata {
        return .{ .allocator = alloc };
    }

    /// Free all allocated memory
    pub fn deinit(self: *Metadata) void {
        self.languages.deinit(self.allocator);
        self.description.deinit(self.allocator);
    }

    /// Add a description entry (language code -> description text)
    fn addDescription(self: *Metadata, key: []const u8, value: []const u8) !void {
        try self.description.put(self.allocator, key, value);
    }

    /// Add a supported language code
    fn appendLanguage(self: *Metadata, lang: []const u8) !void {
        try self.languages.append(self.allocator, lang);
    }
};

/// Create a MetadataReader for parsing metadata from a DataReader
pub fn metadataReader(reader: DataReader) MetadataReader {
    return .{ .reader = reader };
}

/// MetadataReader parses the metadata section of an MMDB file.
/// It reads a map of key-value pairs where each key is a string
/// and values can be various types (integers, strings, maps, arrays).
pub const MetadataReader = struct {
    reader: DataReader,

    /// Read and parse all metadata fields from the database
    pub fn read(self: *MetadataReader, metadata: *Metadata) !void {
        // Metadata is always stored as a map at the start of the metadata section
        try self.reader.assertNextType(.map);
        const len = try self.reader.readPayloadSize();

        // Iterate through each key-value pair in the metadata map
        for (0..len) |_| {
            const key = try self.reader.readString();

            // Parse each known metadata field based on the key name
            if (std.mem.eql(u8, key, "binary_format_major_version")) {
                metadata.binary_format_major_version = try self.reader.readUint16();
            } else if (std.mem.eql(u8, key, "binary_format_minor_version")) {
                metadata.binary_format_minor_version = try self.reader.readUint16();
            } else if (std.mem.eql(u8, key, "build_epoch")) {
                metadata.build_epoch = try self.reader.readUint64();
            } else if (std.mem.eql(u8, key, "database_type")) {
                metadata.database_type = try self.reader.readString();
            } else if (std.mem.eql(u8, key, "description")) {
                try self.readDescriptionMap(metadata);
            } else if (std.mem.eql(u8, key, "ip_version")) {
                metadata.ip_version = try self.reader.readUint16();
            } else if (std.mem.eql(u8, key, "languages")) {
                try self.readLanguagesArray(metadata);
            } else if (std.mem.eql(u8, key, "node_count")) {
                metadata.node_count = try self.reader.readUint32();
            } else if (std.mem.eql(u8, key, "record_size")) {
                metadata.record_size = try self.reader.readUint16();
            } else unreachable;
        }
    }

    /// Read the description map (language code -> description)
    fn readDescriptionMap(self: *MetadataReader, metadata: *Metadata) !void {
        try self.reader.assertNextType(.map);
        const len = try self.reader.readPayloadSize();
        for (0..len) |_| {
            const key = try self.reader.readString();
            const value = try self.reader.readString();
            try metadata.addDescription(key, value);
        }
    }

    /// Read the list of supported languages
    fn readLanguagesArray(self: *MetadataReader, metadata: *Metadata) !void {
        try self.reader.assertNextType(.array);
        const len = try self.reader.readPayloadSize();
        for (0..len) |_| {
            const lang = try self.reader.readString();
            try metadata.appendLanguage(lang);
        }
    }
};

/// Create a MetadataWriter for serializing metadata to JSON
pub fn metadataWriter(metadata: Metadata) MetadataWriter {
    return .{ .metadata = metadata };
}

/// MetadataWriter converts Metadata struct to JSON format.
/// It writes the metadata as a JSON object with all fields.
const MetadataWriter = struct {
    metadata: Metadata,

    /// Write metadata as JSON to the provided writer
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

// Verify the DataReader module is available
test {
    _ = DataReader;
}
