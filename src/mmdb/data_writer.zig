// GeoIP2-zig - MIT License
// MMDB data writer - serializes binary data to JSON

const DataReader = @import("data_reader.zig").DataReader;

/// Error type for data writer operations
pub const Error = anyerror;

/// Create a new DataWriter for writing data at a given offset
///
/// Parameters:
/// - data_offset: Base offset for resolving pointer values
pub fn dataWriter(data_offset: usize) DataWriter {
    return .{ .data_offset = data_offset };
}

/// DataWriter converts binary MMDB data to JSON.
/// It reads data types from a DataReader and writes them
/// to a JSON writer (e.g., std.json.Stringify).
pub const DataWriter = struct {
    /// Base offset used for resolving pointers
    data_offset: usize,

    /// Main entry point: write any data type to the writer
    pub fn writeObject(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const dt = reader.decodeNextType();
        switch (dt) {
            .pointer => try self.writePointer(reader, writer),
            .string => try self.writeString(reader, writer),
            .map => try self.writeMap(reader, writer),
            .array => try self.writeArray(reader, writer),
            .boolean => try self.writeBoolean(reader, writer),
            .uint16 => try self.writeUint16(reader, writer),
            .uint32 => try self.writeUint32(reader, writer),
            .uint64 => try self.writeUint64(reader, writer),
            .uint128 => try self.writeUint128(reader, writer),
            .double => try self.writeDouble(reader, writer),
            else => @panic("Unimplemented"),
        }
    }

    /// Write a pointer by resolving it to the actual data.
    /// Pointers contain an offset from the data section start.
    pub fn writePointer(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const pointer: usize = try reader.readPointer();
        // Save current position, jump to pointer location, read data, restore position
        const current_offset = reader.offset;
        reader.offset = self.data_offset + pointer;
        try self.writeObject(reader, writer);
        reader.offset = current_offset;
    }

    /// Write a map (key-value pairs) as JSON object
    pub fn writeMap(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.map);
        const l = try reader.readPayloadSize();
        try writer.beginObject();
        for (0..l) |_| {
            // Map keys can be strings or pointers to strings
            const key: []const u8 = try reader.readMapKey();
            try writer.objectField(key);
            try self.writeObject(reader, writer);
        }
        try writer.endObject();
    }

    /// Write an array as JSON array
    pub fn writeArray(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.array);
        const l = try reader.readPayloadSize();
        try writer.beginArray();
        for (0..l) |_| {
            try self.writeObject(reader, writer);
        }
        try writer.endArray();
    }

    /// Write a boolean value.
    /// In MMDB, booleans are encoded with size 0 = false, size > 0 = true
    pub fn writeBoolean(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.boolean);
        const l = try reader.readPayloadSize();
        try writer.write(l != 0);
    }

    /// Write a UTF-8 string
    pub fn writeString(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const s: []const u8 = try reader.readString();
        try writer.write(s);
    }

    /// Write an unsigned 16-bit integer
    pub fn writeUint16(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u16 = try reader.readUint16();
        try writer.write(u);
    }

    /// Write an unsigned 32-bit integer
    pub fn writeUint32(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u32 = try reader.readUint32();
        try writer.write(u);
    }

    /// Write an unsigned 64-bit integer
    pub fn writeUint64(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u64 = try reader.readUint64();
        try writer.write(u);
    }

    /// Write an unsigned 128-bit integer
    pub fn writeUint128(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u128 = try reader.readUint128();
        try writer.write(u);
    }

    /// Write a 64-bit IEEE 754 double-precision float
    pub fn writeDouble(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: f64 = try reader.readDouble();
        try writer.write(u);
    }
};
