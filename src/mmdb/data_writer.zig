// GeoIP2-zig
// MMDB data writer - serializes binary data to JSON

const std = @import("std");
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

/// Maximum nesting depth. Real MMDB records nest only a few levels, and the
/// limit stops a self-referential pointer from recursing until the stack
/// overflows.
const max_depth = 256;

/// DataWriter converts binary MMDB data to JSON.
/// It reads data types from a DataReader and writes them
/// to a JSON writer (e.g., std.json.Stringify).
pub const DataWriter = struct {
    /// Base offset used for resolving pointers
    data_offset: usize,

    /// Main entry point: write any data type to the writer
    pub fn writeObject(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        return self.writeValue(reader, writer, 0);
    }

    fn writeValue(self: DataWriter, reader: *DataReader, writer: anytype, depth: usize) Error!void {
        if (depth >= max_depth) return error.InvalidFormat;
        const dt = try reader.decodeNextType();
        switch (dt) {
            .pointer => try self.writePointer(reader, writer, depth),
            .string => try self.writeString(reader, writer),
            .map => try self.writeMap(reader, writer, depth),
            .array => try self.writeArray(reader, writer, depth),
            .boolean => try self.writeBoolean(reader, writer),
            .uint16 => try self.writeUint16(reader, writer),
            .uint32 => try self.writeUint32(reader, writer),
            .uint64 => try self.writeUint64(reader, writer),
            .uint128 => try self.writeUint128(reader, writer),
            .double => try self.writeDouble(reader, writer),
            else => return error.InvalidFormat,
        }
    }

    /// Write a pointer by resolving it to the actual data.
    /// Pointers contain an offset from the data section start.
    pub fn writePointer(self: DataWriter, reader: *DataReader, writer: anytype, depth: usize) Error!void {
        const pointer: usize = try reader.readPointer();
        const target = std.math.add(usize, self.data_offset, pointer) catch
            return error.InvalidFormat;
        if (target >= reader.data.len) return error.InvalidFormat;
        // Save current position, jump to pointer location, read data, restore position
        const current_offset = reader.offset;
        reader.offset = target;
        try self.writeValue(reader, writer, depth + 1);
        reader.offset = current_offset;
    }

    /// Write a map (key-value pairs) as JSON object
    pub fn writeMap(self: DataWriter, reader: *DataReader, writer: anytype, depth: usize) Error!void {
        try reader.assertNextType(.map);
        const l = try reader.readPayloadSize();
        try writer.beginObject();
        for (0..l) |_| {
            // Map keys can be strings or pointers to strings
            const key: []const u8 = try reader.readMapKey();
            try writer.objectField(key);
            try self.writeValue(reader, writer, depth + 1);
        }
        try writer.endObject();
    }

    /// Write an array as JSON array
    pub fn writeArray(self: DataWriter, reader: *DataReader, writer: anytype, depth: usize) Error!void {
        try reader.assertNextType(.array);
        const l = try reader.readPayloadSize();
        try writer.beginArray();
        for (0..l) |_| {
            try self.writeValue(reader, writer, depth + 1);
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

test "rejects a self-referential pointer" {
    // Pointer size 0, value 0: points back at itself.
    var arr = [_]u8{ 0x20, 0x00 };
    var reader = DataReader{ .data = &arr, .data_offset = 0 };
    var out: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var json_stringify: std.json.Stringify = .{ .writer = &writer };
    try std.testing.expectError(
        error.InvalidFormat,
        dataWriter(0).writeObject(&reader, &json_stringify),
    );
}
