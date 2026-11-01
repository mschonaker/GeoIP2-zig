// GeoIP2-zig
// MMDB data writer - serializes binary data to JSON.

const std = @import("std");
const DataReader = @import("data_reader.zig").DataReader;

/// Error type for data writer operations.
pub const Error = anyerror;

/// Maximum nesting depth. Real MMDB records nest only a few levels, and the
/// limit stops a self-referential pointer from recursing until the stack
/// overflows.
const max_depth = 256;

/// Write the value at the reader's offset as JSON to the given writer.
pub fn writeObject(reader: *DataReader, writer: anytype) Error!void {
    return writeValue(reader, writer, 0);
}

fn writeValue(reader: *DataReader, writer: anytype, depth: usize) Error!void {
    if (depth >= max_depth) return error.InvalidFormat;
    const dt = try reader.decodeNextType();
    switch (dt) {
        .pointer => try writePointer(reader, writer, depth),
        .string => try writeString(reader, writer),
        .map => try writeMap(reader, writer, depth),
        .array => try writeArray(reader, writer, depth),
        .boolean => try writeBoolean(reader, writer),
        .uint16 => try writeUint16(reader, writer),
        .uint32 => try writeUint32(reader, writer),
        .uint64 => try writeUint64(reader, writer),
        .uint128 => try writeUint128(reader, writer),
        .double => try writeDouble(reader, writer),
        else => return error.InvalidFormat,
    }
}

/// Write a pointer by resolving it to the actual data.
fn writePointer(reader: *DataReader, writer: anytype, depth: usize) Error!void {
    const target = try reader.readPointerTarget();
    // Save current position, jump to pointer location, read data, restore position.
    const current_offset = reader.offset;
    reader.offset = target;
    try writeValue(reader, writer, depth + 1);
    reader.offset = current_offset;
}

/// Write a map (key-value pairs) as JSON object.
fn writeMap(reader: *DataReader, writer: anytype, depth: usize) Error!void {
    try reader.assertNextType(.map);
    const l = try reader.readPayloadSize();
    try writer.beginObject();
    for (0..l) |_| {
        // Map keys can be strings or pointers to strings.
        const key: []const u8 = try reader.readMapKey();
        try writer.objectField(key);
        try writeValue(reader, writer, depth + 1);
    }
    try writer.endObject();
}

/// Write an array as JSON array.
fn writeArray(reader: *DataReader, writer: anytype, depth: usize) Error!void {
    try reader.assertNextType(.array);
    const l = try reader.readPayloadSize();
    try writer.beginArray();
    for (0..l) |_| {
        try writeValue(reader, writer, depth + 1);
    }
    try writer.endArray();
}

/// Write a boolean value.
/// In MMDB, booleans are encoded with size 0 = false, size > 0 = true.
fn writeBoolean(reader: *DataReader, writer: anytype) Error!void {
    try reader.assertNextType(.boolean);
    const l = try reader.readPayloadSize();
    try writer.write(l != 0);
}

/// Write a UTF-8 string.
fn writeString(reader: *DataReader, writer: anytype) Error!void {
    const s: []const u8 = try reader.readString();
    try writer.write(s);
}

/// Write an unsigned 16-bit integer.
fn writeUint16(reader: *DataReader, writer: anytype) Error!void {
    const u: u16 = try reader.readUint16();
    try writer.write(u);
}

/// Write an unsigned 32-bit integer.
fn writeUint32(reader: *DataReader, writer: anytype) Error!void {
    const u: u32 = try reader.readUint32();
    try writer.write(u);
}

/// Write an unsigned 64-bit integer.
fn writeUint64(reader: *DataReader, writer: anytype) Error!void {
    const u: u64 = try reader.readUint64();
    try writer.write(u);
}

/// Write an unsigned 128-bit integer.
fn writeUint128(reader: *DataReader, writer: anytype) Error!void {
    const u: u128 = try reader.readUint128();
    try writer.write(u);
}

/// Write a 64-bit IEEE 754 double-precision float.
fn writeDouble(reader: *DataReader, writer: anytype) Error!void {
    const u: f64 = try reader.readDouble();
    try writer.write(u);
}

////////////////////////////////////////////////////////////////////////////////

test "rejects a self-referential pointer" {
    // Pointer size 0, value 0: points back at itself.
    var arr = [_]u8{ 0x20, 0x00 };
    var reader = DataReader{ .data = &arr, .data_offset = 0 };
    var out: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var json_stringify: std.json.Stringify = .{ .writer = &writer };
    try std.testing.expectError(
        error.InvalidFormat,
        writeObject(&reader, &json_stringify),
    );
}
