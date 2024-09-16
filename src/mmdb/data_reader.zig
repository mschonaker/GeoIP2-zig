const std = @import("std");

pub const Error = error{
    UnexpectedType,
    InvalidFormat,
};

/// A factory method that returns a **DataReader**.
pub fn dataReader(data: []const u8, offset: usize, comptime enable_assertions: bool, data_offset: usize) DataReader {
    return .{
        .data = data,
        .offset = offset,
        // Required to resolve pointers.
        // It is okay to initialize it with undefined if not supposed to be used.
        .data_offset = data_offset,
        .enable_assertions = enable_assertions,
    };
}

pub const DataReader = struct {
    data: []const u8,
    offset: usize = 0,
    data_offset: usize = undefined,
    comptime enable_assertions: bool = true,

    pub fn decodeNextType(self: *DataReader) DataType {
        // loop: while (true) {
        const x = self.data[self.offset] >> 5;
        return switch (x) {
            0 => // extended
            {
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
                    else => {
                        // Panic. We shouldn't reach here. Kill the process
                        // before it makes any damage.
                        @panic("Invalid type: " ++ [_]u8{x});
                    },
                };
            },
            1 => .pointer,
            2 => .string,
            3 => .double,
            4 => .bytes,
            5 => .uint16,
            6 => .uint32,
            7 => .map,
            else => {
                // Panic. We shouldn't reach here. Kill the process
                // before it makes any damage.
                @panic("Invalid type: " ++ [_]u8{x});
            },
        };
        // }
    }

    /// Returns error.UnexpectedType if assertions are enabled and the type
    /// doesn't match the expected.
    pub inline fn assertNextType(self: *DataReader, comptime expected: DataType) !void {
        if (!self.enable_assertions) return;

        const decoded = self.decodeNextType();
        if (decoded == expected) return;

        // There is not way this code can recover from this kind of error.
        // It would be okay to panic, but we have to let the invoker decide.
        std.debug.print("Unexpected type: {any}, expected: {any}\n", .{ decoded, expected });
        return error.UnexpectedType;
    }

    /// "Variadic args" version of **assertNextType**.
    pub inline fn assertNextTypes(self: *DataReader, expecteds: []const DataType) !void {
        if (!self.enable_assertions) return;

        const decoded = self.decodeNextType();
        inline for (expecteds) |expected|
            if (decoded == expected) return;

        // There is not way this code can recover from this kind of error.
        // It would be okay to panic, but we have to let the invoker decide.
        std.debug.print("Unexpected type: {any}, expected: {any}\n", .{ decoded, expecteds });
        return error.UnexpectedType;
    }

    inline fn bytesToUsize(comptime amount: usize, bytes: []const u8) usize {
        var accum: usize = 0;
        inline for (0..amount) |i|
            accum = accum << 8 | bytes[i];
        return accum;
    }

    pub fn readPayloadSize(self: *DataReader) !usize {
        // Extra increment in the base cursor position if the type
        // was extended.
        var gap: usize = 0;
        // if extended type, increment by one.
        if ((self.data[self.offset] & 0b11100000) == 0) gap = 1;

        const len = self.data[self.offset] & 0b00011111;
        switch (len) {
            0...28 => {
                self.offset += gap + 1;
                return len;
            },
            29 => {
                const r: usize = 29 //
                + bytesToUsize(1, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 2;
                return r;
            },
            30 => {
                const r: usize = 285 //
                + bytesToUsize(2, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 3;
                return r;
            },
            31 => {
                const r: usize = 65821 //
                + bytesToUsize(3, self.data[self.offset + gap + 1 ..]);
                self.offset += gap + 4;
                return r;
            },
            else => return error.InvalidFormat,
        }
    }

    pub fn readPointer(self: *DataReader) !usize {
        try self.assertNextType(.pointer);

        // Size is computed differently in the 001SSVVV fashion described in
        // the spec.
        const byte = self.data[self.offset];
        const size: u8 = (byte & 0b00011000) >> 3;
        const remainder: usize = byte & 0b00000111;
        switch (size) {
            0 => {
                var accum: usize = remainder << 8;
                accum |= bytesToUsize(1, self.data[self.offset + 1 ..]);
                self.offset += 2;
                return accum;
            },
            1 => {
                var accum: usize = remainder << 16;
                accum |= bytesToUsize(2, self.data[self.offset + 1 ..]);
                accum += 2048;
                self.offset += 3;
                return accum;
            },
            2 => {
                var accum: usize = remainder << 24;
                accum |= bytesToUsize(3, self.data[self.offset + 1 ..]);
                accum += 526336;
                self.offset += 4;
                return accum;
            },
            3 => {
                const accum: usize = bytesToUsize(4, self.data[self.offset + 1 ..]);
                self.offset += 5;
                return accum;
            },
            else => return error.InvalidFormat,
        }
    }

    pub fn readString(self: *DataReader) ![]const u8 {
        try self.assertNextType(.string);

        const len = try self.readPayloadSize();
        const s = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return s;
    }

    pub fn readMapKey(self: *DataReader) ![]const u8 {
        try self.assertNextTypes(&.{ .string, .pointer });
        switch (self.decodeNextType()) {
            .string => return try self.readString(),
            .pointer => {
                const p = try self.readPointer();
                const current = self.offset;
                self.offset = self.data_offset + p;
                const s = self.readString();
                self.offset = current;
                return s;
            },
            else => unreachable,
        }
    }

    pub fn readBytes(self: *DataReader) ![]const u8 {
        try self.assertNextType(.bytes);

        const len = try self.readPayloadSize();
        const s = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return s;
    }

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

    pub fn readDouble(self: *DataReader) !f64 {
        try self.assertNextType(.double);

        // Read the offset.
        self.offset += 1;

        var accum: u64 = 0;
        for (0..8) |_| {
            accum <<= 8;
            accum |= @as(u64, self.data[self.offset]);
            self.offset += 1;
        }
        return @floatFromInt(accum);
    }

    pub fn readUint128(self: *DataReader) !u128 {
        try self.assertNextType(.uint128);

        const len = self.readPayloadSize();
        if (len == 0) return 0;
        var accum: u128 = 0;
        for (0..len) |_| {
            accum <<= 8;
            accum += @as(u128, self.data[self.offset]);
            self.offset += 1;
        }
        return accum;
    }
};

/// For reference: https://github.com/maxmind/MaxMind-DB-Reader-java/blob/main/src/main/java/com/maxmind/db/Type.java#L4
const DataType = enum {
    pointer, // 1
    string, // 2
    double, // 3
    bytes, // 4
    uint16, // 5
    uint32, // 6
    map, // 7
    int32, // 8
    uint64, // 9
    uint128, // 10
    array, // 11
    container, // 12
    end, // 13
    boolean, // 14
    float, // 15
};

////////////////////////////////////////////////////////////////////////////////

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "string lengths" {
    // 01011101 00110011 UTF-8 string - 80 bytes long
    {
        var arr = [_]u8{ 0b01011101, 0b00110011 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(80, reader.readPayloadSize());
        try expectEqual(2, reader.offset);
    }

    // 01011110 00110011 00110011 UTF-8 string - 13,392 bytes long
    {
        var arr = [_]u8{ 0b01011110, 0b00110011, 0b00110011 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(13392, reader.readPayloadSize());
        try expectEqual(3, reader.offset);
    }

    // 01011111 00110011 00110011 00110011 UTF-8 string - 3,421,264 bytes long
    {
        var arr = [_]u8{ 0b01011111, 0b00110011, 0b00110011, 0b00110011 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(3421264, reader.readPayloadSize());
        try expectEqual(4, reader.offset);
    }
}

test "readUint tests" {
    // read a u16 of 1 byte and value 2.
    {
        var arr = [_]u8{ 0b10100001, 0b00000010, 0b01011011 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(2, reader.readUint16());
        try expectEqual(2, reader.offset);
    }

    // read a u16 of 0 bytes and value 0.
    {
        var arr = [_]u8{ 0b10100000, 0b00000010, 0b01011011 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(0, reader.readUint16());
        try expectEqual(1, reader.offset);
    }
}

test "readUint u64" {

    // { 00000100, 00000010, 01100110, ...}
    // first nibble is 0 (extension),
    // second byte second nibble is 2, meaning type 9 (u64)
    // first byte second nibble is 4, indicating the length of 4 bytes.
    {
        var arr = [_]u8{ 0b00000100, 0b00000010, 0b01100110, 0b11010110, 0b11110111, 0b00001000, 0b01001101 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual((0b01100110 << 24) + (0b11010110 << 16) + (0b11110111 << 8) + 0b00001000, //
            reader.readUint64() //
        );
        try expectEqual(6, reader.offset);
    }
}

test "read pointers" {
    // https://github.com/maxmind/MaxMind-DB-Reader-java/blob/main/src/test/java/com/maxmind/db/DecoderTest.java#L117
    {
        var arr = [_]u8{ 0x20, 0x0 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(0, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x20, 0x5 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(5, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x20, 0xa };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(10, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x20, 0xa };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(10, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x23, 0xff };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(1023, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x28, 0x3, 0xc9 };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(3017, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x2f, 0xf7, 0xfb };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(524283, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x2f, 0xff, 0xff };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(526_335, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x37, 0xf7, 0xf7, 0xfe };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(134_217_726, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x37, 0xff, 0xff, 0xff };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(134_744_063, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
    {
        var arr = [_]u8{ 0x38, 0x7f, 0xff, 0xff, 0xff };
        var reader = DataReader{
            .data = &arr,
        };
        try expectEqual(2_147_483_647, reader.readPointer());
        try expectEqual(arr.len, reader.offset);
    }
}
