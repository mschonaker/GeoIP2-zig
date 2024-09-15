const std = @import("std");
const io = std.io;
const json = std.json;

const mmdb_data_reader = @import("data_reader.zig");
const DataReader = mmdb_data_reader.DataReader;

pub fn dataWriter(data_offset: usize) DataWriter {
    return .{
        .data_offset = data_offset,
    };
}

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

const ReaderError = error{
    UnexpectedType,
};

const Error = WriterError || ReaderError;

pub const DataWriter = struct {
    data_offset: usize,

    pub fn writeObject(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const dt = reader.decodeNextType();
        switch (dt) {
            .pointer => try self.writePointer(reader, writer),
            .string => try self.writeString(reader, writer),
            .map => try self.writeMap(reader, writer),
            .uint16 => try self.writeUint16(reader, writer),
            .uint32 => try self.writeUint32(reader, writer),
            .double => try self.writeDouble(reader, writer),
            .array => try self.writeArray(reader, writer),
            .boolean => try self.writeBoolean(reader, writer),
            else => {
                std.debug.print("Uninmplemented: {any}\n", .{dt});
                unreachable;
            },
        }
    }

    pub fn writePointer(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const p = try reader.readPointer();
        const current = reader.offset;
        reader.offset = self.data_offset + p;
        try self.writeObject(reader, writer);
        reader.offset = current;
    }

    pub fn writeString(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const s = try reader.readString();
        try writer.write(s);
    }

    pub fn writeUint16(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u = try reader.readUint16();
        try writer.write(u);
    }

    pub fn writeUint32(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u = try reader.readUint32();
        try writer.write(u);
    }

    pub fn writeDouble(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        const u = try reader.readDouble();
        try writer.write(u);
    }

    pub fn writeMap(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.map);
        const l = reader.readPayloadSize();
        try writer.beginObject();
        for (0..l) |_| {
            const key = try reader.readMapKey();
            try writer.objectField(key);
            try self.writeObject(reader, writer);
        }
        try writer.endObject();
    }

    pub fn writeArray(self: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.array);
        const l = reader.readPayloadSize();
        try writer.beginArray();
        for (0..l) |_| {
            try self.writeObject(reader, writer);
        }
        try writer.endArray();
    }

    pub fn writeBoolean(_: DataWriter, reader: *DataReader, writer: anytype) Error!void {
        try reader.assertNextType(.boolean);
        const l = reader.readPayloadSize();
        try writer.write(l != 0);
    }
};
