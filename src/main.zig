const std = @import("std");
const fs = std.fs;
const io = std.io;
const fmt = std.fmt;

const mmdb = @import("mmdb/mmdb.zig");
const embeded = @embedFile("GeoLite2-City.mmdb");

const MMDBFile = mmdb.MMDBFile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mmdbfile = try mmdb.MMDBFile.init(embeded, allocator, true);
    defer mmdbfile.deinit();

    var stdout = io.bufferedWriter(io.getStdOut().writer());
    defer stdout.flush() catch {};
    try mmdbfile.print(stdout.writer());

    try stdout.writer().print("=" ** 80, .{});

    try mmdbfile.resolveIpV4([_]u8{ 168, 197, 202, 44 }, stdout.writer());
    // try mmdbfile.resolveIpV4([_]u8{ 127, 0, 0, 0 }, stdout.writer());
    // try mmdbfile.resolveIpV4([_]u8{ 8, 8, 4, 4 }, stdout.writer());
    // try mmdbfile.resolveIpV4([_]u8{ 59, 79, 218, 34 }, stdout.writer());

    // var offset = try mmdbfile.writeData(mmdbfile.nodes_offset, stdout.writer());
    // var offset = try mmdbfile.writeData(53162222, stdout.writer());
    // for (0..1000000) |_| {
    //     defer stdout.flush() catch {};
    //     try stdout.writer().print("\n" ++ "*" ** 80 ++ "\n", .{});
    //     try stdout.writer().print("* {d}\n", .{offset});
    //     try stdout.writer().print("*" ** 80 ++ "\n", .{});
    //     offset = try mmdbfile.writeData(offset, stdout.writer());
    // }
}

test {
    _ = mmdb;
}
