// GeoIP2-zig
// MMDB data writer - serializes binary data to JSON.

const std = @import("std");
const DataReader = @import("data_reader.zig").DataReader;
const projection_mod = @import("projection.zig");
const Projection = projection_mod.Projection;

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

/// Write the value at the reader's offset as projected JSON. Only the fields
/// selected by the projection are serialized; the rest of the binary tree is
/// traversed but never decoded to JSON.
pub fn writeProjection(reader: *DataReader, writer: anytype, projection: *const Projection) Error!void {
    var all: [projection_mod.max_paths]usize = undefined;
    for (0..projection.count) |i| all[i] = i;
    const root = Filter{
        .active = all[0..projection.count],
        .depth = 0,
        .whole = !projection.has_includes,
    };
    if (!root.whole and try peekKind(reader) == .scalar) {
        // No path can reach a scalar root, so nothing is selected.
        try writer.write(@as(?u8, null));
        return;
    }
    try writeFilteredValue(reader, writer, projection, root, 0);
}

/// The requested paths that matched the container being serialized.
const Filter = struct {
    /// Indices into the projection's paths whose segments matched the
    /// container's ancestry so far.
    active: []const usize,
    /// Segments consumed to reach the container.
    depth: usize,
    /// Every field below the container is selected, subject to exclusions.
    whole: bool,
};

const Kind = enum { scalar, map, array };

/// Determine the type of the next value, following pointers. The reader
/// position is restored.
fn peekKind(reader: *DataReader) Error!Kind {
    const saved = reader.offset;
    defer reader.offset = saved;
    var dt = try reader.decodeNextType();
    var hops: usize = 0;
    while (dt == .pointer) {
        hops += 1;
        if (hops == 8) return error.InvalidFormat;
        reader.offset = try reader.readPointerTarget();
        dt = try reader.decodeNextType();
    }
    return switch (dt) {
        .map => .map,
        .array => .array,
        else => .scalar,
    };
}

const Decision = union(enum) {
    skip,
    whole,
    container: Filter,
};

/// Decide whether and how to write one child of a projected container. The
/// matched path indices are written into `out`.
fn decide(
    reader: *DataReader,
    projection: *const Projection,
    filter: Filter,
    child: projection_mod.Child,
    out: []usize,
) Error!Decision {
    const m = projection.match(filter.active, filter.depth, child, out);
    const whole = filter.whole or m.inc_term;
    if (m.suppress or (!whole and !m.inc_deep)) return .skip;
    if (!m.deep) return .whole;
    if (try peekKind(reader) == .scalar) return if (whole) .whole else .skip;
    return .{ .container = .{
        .active = m.paths,
        .depth = filter.depth + 1,
        .whole = whole,
    } };
}

/// Write a projected value, following pointers into containers. Scalars are
/// written whole; scalars under a descending path never reach this function.
fn writeFilteredValue(
    reader: *DataReader,
    writer: anytype,
    projection: *const Projection,
    filter: Filter,
    depth: usize,
) Error!void {
    if (depth >= max_depth) return error.InvalidFormat;
    const dt = try reader.decodeNextType();
    switch (dt) {
        .pointer => {
            const target = try reader.readPointerTarget();
            const current_offset = reader.offset;
            reader.offset = target;
            try writeFilteredValue(reader, writer, projection, filter, depth + 1);
            reader.offset = current_offset;
        },
        .map => try writeFilteredMap(reader, writer, projection, filter, depth),
        .array => try writeFilteredArray(reader, writer, projection, filter, depth),
        else => try writeValue(reader, writer, depth),
    }
}

/// Advance the reader past a value without writing it.
fn skipValue(reader: *DataReader, depth: usize) Error!void {
    if (depth >= max_depth) return error.InvalidFormat;
    const dt = try reader.decodeNextType();
    switch (dt) {
        .pointer => _ = try reader.readPointerTarget(),
        .string => _ = try reader.readString(),
        .boolean => _ = try reader.readPayloadSize(),
        .uint16 => _ = try reader.readUint16(),
        .uint32 => _ = try reader.readUint32(),
        .uint64 => _ = try reader.readUint64(),
        .uint128 => _ = try reader.readUint128(),
        .double => _ = try reader.readDouble(),
        .map, .array => {
            const len = try reader.readPayloadSize();
            for (0..len) |_| {
                if (dt == .map) try skipValue(reader, depth + 1);
                try skipValue(reader, depth + 1);
            }
        },
        else => return error.InvalidFormat,
    }
}

/// Write a map as a JSON object containing only the projected fields.
fn writeFilteredMap(
    reader: *DataReader,
    writer: anytype,
    projection: *const Projection,
    filter: Filter,
    depth: usize,
) Error!void {
    try reader.assertNextType(.map);
    const len = try reader.readPayloadSize();
    try writer.beginObject();
    for (0..len) |_| {
        const key = try reader.readMapKey();
        var matched: [projection_mod.max_paths]usize = undefined;
        switch (try decide(reader, projection, filter, .{ .key = key }, &matched)) {
            .skip => try skipValue(reader, depth + 1),
            .whole => {
                try writer.objectField(key);
                try writeValue(reader, writer, depth + 1);
            },
            .container => |below| {
                try writer.objectField(key);
                try writeFilteredValue(reader, writer, projection, below, depth + 1);
            },
        }
    }
    try writer.endObject();
}

/// Write an array as a JSON array containing only the projected elements.
fn writeFilteredArray(
    reader: *DataReader,
    writer: anytype,
    projection: *const Projection,
    filter: Filter,
    depth: usize,
) Error!void {
    try reader.assertNextType(.array);
    const len = try reader.readPayloadSize();
    try writer.beginArray();
    for (0..len) |index| {
        var matched: [projection_mod.max_paths]usize = undefined;
        switch (try decide(reader, projection, filter, .{ .index = index }, &matched)) {
            .skip => try skipValue(reader, depth + 1),
            .whole => try writeValue(reader, writer, depth + 1),
            .container => |below| try writeFilteredValue(reader, writer, projection, below, depth + 1),
        }
    }
    try writer.endArray();
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

// {"a":{"x":1,"y":2},"b":"z","c":[10,20,30]} encoded as MMDB data.
const map_data = [_]u8{
    0xE3,
    0x41,
    'a',
    0xE2,
    0x41,
    'x',
    0xA1,
    0x01,
    0x41,
    'y',
    0xA1,
    0x02,
    0x41,
    'b',
    0x41,
    'z',
    0x41,
    'c',
    0x03,
    0x04,
    0xA1,
    0x0A,
    0xA1,
    0x14,
    0xA1,
    0x1E,
};

fn project(spec: []const u8, expected: []const u8) !void {
    const projection = try Projection.parse(spec);
    var reader = DataReader{ .data = &map_data, .data_offset = 0 };
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var json_stringify: std.json.Stringify = .{ .writer = &writer };
    try writeProjection(&reader, &json_stringify, &projection);
    try std.testing.expectEqualStrings(expected, out[0..writer.end]);
}

test "projection selects nested fields" {
    try project("a.x", "{\"a\":{\"x\":1}}");
    try project("a.(x,y)", "{\"a\":{\"x\":1,\"y\":2}}");
    try project("a,b", "{\"a\":{\"x\":1,\"y\":2},\"b\":\"z\"}");
    try project("b", "{\"b\":\"z\"}");
    try project("zz", "{}");
    try project("*", "{\"a\":{\"x\":1,\"y\":2},\"b\":\"z\",\"c\":[10,20,30]}");
}

test "projection wildcards and array indices" {
    // "*" matches any key or element, so "c" is a requested container and
    // serializes empty when no element below it matches.
    try project("*.x", "{\"a\":{\"x\":1},\"c\":[]}");
    try project("c.1", "{\"c\":[20]}");
    try project("c.*", "{\"c\":[10,20,30]}");
    try project("c", "{\"c\":[10,20,30]}");
    try project("0,c.0", "{\"c\":[10]}");
}

test "projection excludes with precedence over includes" {
    try project("!b", "{\"a\":{\"x\":1,\"y\":2},\"c\":[10,20,30]}");
    try project("!a.y", "{\"a\":{\"x\":1},\"b\":\"z\",\"c\":[10,20,30]}");
    try project("a,!a.x", "{\"a\":{\"y\":2}}");
    try project("a,!a", "{}");
    try project("!c.0", "{\"a\":{\"x\":1,\"y\":2},\"b\":\"z\",\"c\":[20,30]}");
    try project("!c.*", "{\"a\":{\"x\":1,\"y\":2},\"b\":\"z\",\"c\":[]}");
}

test "projection descends into scalars select nothing" {
    try project("b.nope", "{}");
    try project("c.0.x", "{\"c\":[]}");
    try project("a.x.y", "{\"a\":{}}");
    try project("a.q", "{\"a\":{}}");
}

test "projection resolves a pointer root" {
    const pointer_root = [_]u8{ 0x20, 0x02 } ++ map_data;
    const projection = try Projection.parse("a.x");
    var reader = DataReader{ .data = &pointer_root, .data_offset = 0 };
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var json_stringify: std.json.Stringify = .{ .writer = &writer };
    try writeProjection(&reader, &json_stringify, &projection);
    try std.testing.expectEqualStrings("{\"a\":{\"x\":1}}", out[0..writer.end]);
}

test "projection on a scalar root" {
    const string_root = [_]u8{ 0x42, 'h', 'i' };

    const excluded = try Projection.parse("!x");
    var reader = DataReader{ .data = &string_root, .data_offset = 0 };
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var json_stringify: std.json.Stringify = .{ .writer = &writer };
    try writeProjection(&reader, &json_stringify, &excluded);
    try std.testing.expectEqualStrings("\"hi\"", out[0..writer.end]);

    const included = try Projection.parse("x");
    var reader2 = DataReader{ .data = &string_root, .data_offset = 0 };
    var out2: [256]u8 = undefined;
    var writer2: std.Io.Writer = .fixed(&out2);
    var json_stringify2: std.json.Stringify = .{ .writer = &writer2 };
    try writeProjection(&reader2, &json_stringify2, &included);
    try std.testing.expectEqualStrings("null", out2[0..writer2.end]);
}
