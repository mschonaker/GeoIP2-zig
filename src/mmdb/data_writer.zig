const std = @import("std");

const mmdb_data_reader = @import("data_reader.zig");
const DataReader = mmdb_data_reader.DataReader;

const WriterError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    WouldBlock,
    ConnectionResetByPeer,
    Unexpected,
};

const ReaderError = mmdb_data_reader.Error;

pub const Error = WriterError || ReaderError;

/// Factory method of a **DataWriter**.
pub fn dataWriter(data_offset: usize) DataWriter {
    return .{
        .data_offset = data_offset,
    };
}

/// Copies data from the reader to the writer.
pub const DataWriter = struct {
    data_offset: usize,

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

    pub fn writePointer(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const pointer: usize = try reader.readPointer();

        // Copy the current offset. Point the reader to the value read.
        const current_offset = reader.offset;
        reader.offset = self.data_offset + pointer;

        // Read anything.
        try self.writeObject(reader, writer);

        // Restore the offset.
        reader.offset = current_offset;
    }

    pub fn writeMap(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.map);

        // read the number of entries.
        const l = try reader.readPayloadSize();

        // Tell the writer to start an object.
        try writer.beginObject();
        for (0..l) |_| {

            // Keys can be a string or a pointer to a string.
            const key: []const u8 = try reader.readMapKey();

            // Write the key, then the object.
            try writer.objectField(key);
            try self.writeObject(reader, writer);
        }

        // Tell the writer to end the object.
        try writer.endObject();
    }

    pub fn writeArray(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.array);
        const l = try reader.readPayloadSize();
        try writer.beginArray();
        for (0..l) |_| {
            try self.writeObject(reader, writer);
        }
        try writer.endArray();
    }

    pub fn writeBoolean(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.boolean);

        // Booleans are encoded in the payload size.
        const l = try reader.readPayloadSize();
        try writer.write(l != 0);
    }

    pub fn writeString(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const s: []const u8 = try reader.readString();
        try writer.write(s);
    }

    pub fn writeUint16(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u16 = try reader.readUint16();
        try writer.write(u);
    }

    pub fn writeUint32(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u32 = try reader.readUint32();
        try writer.write(u);
    }

    pub fn writeUint64(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u64 = try reader.readUint64();
        try writer.write(u);
    }

    pub fn writeUint128(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: u128 = try reader.readUint128();
        try writer.write(u);
    }

    pub fn writeDouble(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u: f64 = try reader.readDouble();
        try writer.write(u);
    }
};
