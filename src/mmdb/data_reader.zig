// GeoIP2-zig
// MMDB binary data reader - parses the MaxMind database binary format

const std = @import("std");

/// Error types for data reader operations
pub const Error = error{
    UnexpectedType,
    InvalidFormat,
};

/// Create a new DataReader for reading MMDB data at a given offset.
///
/// Parameters:
/// - data: The raw MMDB binary data
/// - offset: Starting position to read from
/// - enable_assertions: Enable runtime type checking (expensive)
/// - data_offset: Base offset for resolving pointers
pub fn dataReader(data: []const u8, offset: usize, enable_assertions: bool, data_offset: usize) DataReader {
    return .{
        .data = data,
        .offset = offset,
        .data_offset = data_offset,
        .enable_assertions = enable_assertions,
    };
}

/// DataReader reads and decodes the binary MMDB data format.
/// It provides methods for reading various data types like strings,
/// integers, pointers, maps, and arrays from the binary stream.
pub const DataReader = struct {
    /// The raw binary MMDB data
    data: []const u8,
    /// Current position in the data stream
    offset: usize = 0,
    /// Base offset used for resolving pointer values
    data_offset: usize = undefined,
    /// Enable runtime type assertions (useful for debugging)
    enable_assertions: bool = false,

    /// Decode the next data type from the stream.
    /// The type is encoded in the first 3 bits of the leading byte.
    /// See: https://maxmind.github.io/MaxMind-DB/
    pub fn decodeNextType(self: *DataReader) DataType {
        const x = self.data[self.offset] >> 5;
        return switch (x) {
            // Extended types (first 3 bits are 000)
            0 => {
                // Extended types use a second byte to determine the actual type
                const y = self.data[self.offset + 1] + 7;
                return switch (y) {
                    8 => .int32,
                    9 => .uint64,
                    10 => .uint128,
                    11 => .array,
                    12 => .container,
                    13 => .end,
                    14 => .boolean,
                    15 => .float,
                    else => @panic("Invalid type"),
                };
            },
            // Pointer (used for string deduplication)
            1 => .pointer,
            // UTF-8 string
            2 => .string,
            // Double (64-bit float)
            3 => .double,
            // Byte sequence
            4 => .bytes,
            // Unsigned 16-bit integer
            5 => .uint16,
            // Unsigned 32-bit integer
            6 => .uint32,
            // Map (key-value pairs)
            7 => .map,
            else => @panic("Invalid type"),
        };
    }

    /// Assert that the next type matches the expected type.
    /// Only performs check if enable_assertions is true (compile-time constant).
    /// This is useful for debugging but adds overhead in production.
    pub inline fn assertNextType(self: *DataReader, comptime expected: DataType) !void {
        if (!self.enable_assertions) return;
        const decoded = self.decodeNextType();
        if (decoded == expected) return;
        std.debug.print("Unexpected type: {any}, expected: {any}\n", .{ decoded, expected });
        return error.UnexpectedType;
    }

    /// Assert that the next type matches one of the expected types.
    /// Useful for union types like map keys (string or pointer).
    pub inline fn assertNextTypes(self: *DataReader, expecteds: []const DataType) !void {
        if (!self.enable_assertions) return;
        const decoded = self.decodeNextType();
        inline for (expecteds) |expected|
            if (decoded == expected) return;
        std.debug.print("Unexpected type: {any}, expected: {any}\n", .{ decoded, expecteds });
        return error.UnexpectedType;
    }

    /// Convert a variable-length byte sequence to a usize value.
    /// Used for reading size prefixes and pointer offsets.
    inline fn bytesToUsize(comptime amount: usize, bytes: []const u8) usize {
        var accum: usize = 0;
        inline for (0..amount) |i|
            accum = accum << 8 | bytes[i];
        return accum;
    }

    /// Read a size/value from the stream.
    /// The MMDB format encodes sizes in the lower 5 bits of the first byte:
    /// - 0-28: Direct value (no additional bytes needed)
    /// - 29: Add 1 byte for actual size (range: 29-284)
    /// - 30: Add 2 bytes for actual size (range: 285-65820)
    /// - 31: Add 3 bytes for actual size (range: 65821+)
    pub fn readPayloadSize(self: *DataReader) !usize {
        var gap: usize = 0;
        // Extended types have a leading 0, requiring an extra byte
        if ((self.data[self.offset] & 0b11100000) == 0) gap = 1;
        const len = self.data[self.offset] & 0b00011111;
        switch (len) {
            // Small sizes (0-28 bytes) are stored directly
            0...28 => {
                self.offset += gap + 1;
                return len;
            },
            // Medium sizes: 1 additional byte extends the range
            29 => {
                const r: usize = 29 + bytesToUsize(1, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 2;
                return r;
            },
            // Larger sizes: 2 additional bytes
            30 => {
                const r: usize = 285 + bytesToUsize(2, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 3;
                return r;
            },
            // Largest sizes: 3 additional bytes
            31 => {
                const r: usize = 65821 + bytesToUsize(3, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 4;
                return r;
            },
            else => return error.InvalidFormat,
        }
    }

    /// Read a pointer from the stream.
    /// Pointers are used to reference previously seen strings,
    /// enabling deduplication in the MMDB format.
    /// The pointer format uses bits 3-5 (SS) for size and bits 0-2 (VVV) for value.
    pub fn readPointer(self: *DataReader) !usize {
        try self.assertNextType(.pointer);
        const byte = self.data[self.offset];
        const size: u8 = (byte & 0b00011000) >> 3;
        const remainder: usize = byte & 0b00000111;
        switch (size) {
            // 1-byte pointer: 7-bit value
            0 => {
                var accum: usize = remainder << 8;
                accum |= bytesToUsize(1, self.data[self.offset + 1 ..]);
                self.offset += 2;
                return accum;
            },
            // 2-byte pointer: adds 2048 offset, 14-bit value
            1 => {
                var accum: usize = remainder << 16;
                accum |= bytesToUsize(2, self.data[self.offset + 1 ..]);
                accum += 2048;
                self.offset += 3;
                return accum;
            },
            // 3-byte pointer: adds 526336 offset, 21-bit value
            2 => {
                var accum: usize = remainder << 24;
                accum |= bytesToUsize(3, self.data[self.offset + 1 ..]);
                accum += 526336;
                self.offset += 4;
                return accum;
            },
            // 4-byte pointer: full 32-bit value
            3 => {
                const accum: usize = bytesToUsize(4, self.data[self.offset + 1 ..]);
                self.offset += 5;
                return accum;
            },
            else => return error.InvalidFormat,
        }
    }

    /// Read a UTF-8 string from the stream.
    /// Strings are prefixed with a size value from readPayloadSize.
    pub fn readString(self: *DataReader) ![]const u8 {
        try self.assertNextType(.string);
        const len = try self.readPayloadSize();
        const s = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return s;
    }

    /// Read a map key, which can be either a string or a pointer to a string.
    /// Pointers allow the MMDB format to deduplicate repeated keys.
    pub fn readMapKey(self: *DataReader) ![]const u8 {
        try self.assertNextTypes(&.{ .string, .pointer });
        switch (self.decodeNextType()) {
            .string => return try self.readString(),
            .pointer => {
                // Resolve pointer to actual string location
                const p = try self.readPointer();
                const current_offset = self.offset;
                self.offset = self.data_offset + p;
                const s = self.readString();
                self.offset = current_offset;
                return s;
            },
            else => unreachable,
        }
    }

    /// Read an unsigned 16-bit integer from the stream.
    pub fn readUint16(self: *DataReader) !u16 {
        try self.assertNextType(.uint16);
        const len = try self.readPayloadSize();
        if (len == 0) return 0;
        var accum: u16 = 0;
        for (0..len) |_| {
            accum <<= 8;
            accum += @as(u16, self.data[self.offset]);
            self.offset += 1;
        }
        return accum;
    }

    /// Read an unsigned 32-bit integer from the stream.
    pub fn readUint32(self: *DataReader) !u32 {
        try self.assertNextType(.uint32);
        const len = try self.readPayloadSize();
        if (len == 0) return 0;
        var accum: u32 = 0;
        for (0..len) |_| {
            accum <<= 8;
            accum += @as(u32, self.data[self.offset]);
            self.offset += 1;
        }
        return accum;
    }

    /// Read an unsigned 64-bit integer from the stream.
    pub fn readUint64(self: *DataReader) !u64 {
        try self.assertNextType(.uint64);
        const len = try self.readPayloadSize();
        if (len == 0) return 0;
        var accum: u64 = 0;
        for (0..len) |_| {
            accum <<= 8;
            accum += @as(u64, self.data[self.offset]);
            self.offset += 1;
        }
        return accum;
    }

    /// Read an unsigned 128-bit integer from the stream.
    pub fn readUint128(self: *DataReader) !u128 {
        try self.assertNextType(.uint128);
        const len = try self.readPayloadSize();
        if (len == 0) return 0;
        var accum: u128 = 0;
        for (0..len) |_| {
            accum <<= 8;
            accum += @as(u128, self.data[self.offset]);
            self.offset += 1;
        }
        return accum;
    }

    /// Read a 64-bit IEEE 754 double-precision float from the stream.
    pub fn readDouble(self: *DataReader) !f64 {
        try self.assertNextType(.double);
        self.offset += 1;
        var accum: u64 = 0;
        for (0..8) |_| {
            accum <<= 8;
            accum |= @as(u64, self.data[self.offset]);
            self.offset += 1;
        }
        return @as(f64, @bitCast(accum));
    }
};

/// DataType enumeration representing all possible types in the MMDB format.
/// Each type has a specific encoding in the binary format.
const DataType = enum {
    pointer, // Reference to previously seen data
    string, // UTF-8 encoded text
    double, // 64-bit floating point
    bytes, // Raw byte sequence
    uint16, // Unsigned 16-bit integer
    uint32, // Unsigned 32-bit integer
    map, // Key-value pairs
    int32, // Signed 32-bit integer
    uint64, // Unsigned 64-bit integer
    uint128, // Unsigned 128-bit integer
    array, // Ordered list of values
    container, // Named structure
    end, // End marker
    boolean, // True/false
    float, // 32-bit floating point
};

const expectEqual = std.testing.expectEqual;

// Test: Verify payload size decoding for various lengths
test "string lengths" {
    {
        // 80-byte string (len = 80, fits in 5 bits)
        var arr = [_]u8{ 0b01011101, 0b00110011 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(80, reader.readPayloadSize());
        try expectEqual(2, reader.offset);
    }
    {
        // 13,392-byte string (len = 29 + 1 byte extension)
        var arr = [_]u8{ 0b01011110, 0b00110011, 0b00110011 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(13392, reader.readPayloadSize());
        try expectEqual(3, reader.offset);
    }
    {
        // 3,421,264-byte string (len = 31 + 3 byte extension)
        var arr = [_]u8{ 0b01011111, 0b00110011, 0b00110011, 0b00110011 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(3421264, reader.readPayloadSize());
        try expectEqual(4, reader.offset);
    }
}

// Test: Verify unsigned integer reading
test "readUint tests" {
    {
        // 1-byte u16 with value 2
        var arr = [_]u8{ 0b10100001, 0b00000010, 0b01011011 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(2, reader.readUint16());
        try expectEqual(2, reader.offset);
    }
    {
        // 0-byte u16 (empty)
        var arr = [_]u8{ 0b10100000, 0b00000010, 0b01011011 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(0, reader.readUint16());
        try expectEqual(1, reader.offset);
    }
}

// Test: Verify 64-bit unsigned integer reading
test "readUint u64" {
    {
        var arr = [_]u8{ 0b00000100, 0b00000010, 0b01100110, 0b11010110, 0b11110111, 0b00001000, 0b01001101 };
        var reader = DataReader{ .data = &arr };
        try expectEqual((0b01100110 << 24) + (0b11010110 << 16) + (0b11110111 << 8) + 0b00001000, reader.readUint64());
        try expectEqual(6, reader.offset);
    }
}

// Test: Verify pointer decoding for various pointer sizes
test "read pointers" {
    {
        // Pointer size 0, value 0
        var arr = [_]u8{ 0x20, 0x0 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(0, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 0, value 5
        var arr = [_]u8{ 0x20, 0x5 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(5, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 0, value 10
        var arr = [_]u8{ 0x20, 0xa };
        var reader = DataReader{ .data = &arr };
        try expectEqual(10, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 1, value 1023
        var arr = [_]u8{ 0x23, 0xff };
        var reader = DataReader{ .data = &arr };
        try expectEqual(1023, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 2, value 3017
        var arr = [_]u8{ 0x28, 0x3, 0xc9 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(3017, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 3, max value
        var arr = [_]u8{ 0x2f, 0xf7, 0xfb };
        var reader = DataReader{ .data = &arr };
        try expectEqual(524283, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 3, boundary
        var arr = [_]u8{ 0x2f, 0xff, 0xff };
        var reader = DataReader{ .data = &arr };
        try expectEqual(526_335, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 4, near max
        var arr = [_]u8{ 0x37, 0xf7, 0xf7, 0xfe };
        var reader = DataReader{ .data = &arr };
        try expectEqual(134_217_726, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 4, max value
        var arr = [_]u8{ 0x37, 0xff, 0xff, 0xff };
        var reader = DataReader{ .data = &arr };
        try expectEqual(134_744_063, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // Pointer size 5, max signed 32-bit
        var arr = [_]u8{ 0x38, 0x7f, 0xff, 0xff, 0xff };
        var reader = DataReader{ .data = &arr };
        try expectEqual(2_147_483_647, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
}

test "readDouble" {
    {
        // 1.0 encoded as IEEE 754 double (0x3FF0 0000 0000 0000)
        // Type byte 0x68: top 3 bits = 011 (double), lower 5 = 01000 (size=8)
        var arr = [_]u8{ 0x68, 0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(1.0, reader.readDouble());
        try expectEqual(arr.len, reader.offset);
    }
    {
        // -1.0 encoded as IEEE 754 double (0xBFF0 0000 0000 0000)
        var arr = [_]u8{ 0x68, 0xbf, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
        var reader = DataReader{ .data = &arr };
        try expectEqual(-1.0, reader.readDouble());
        try expectEqual(arr.len, reader.offset);
    }
}
