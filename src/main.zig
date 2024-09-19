const std = @import("std");
const fs = std.fs;
const io = std.io;
const fmt = std.fmt;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const mmdb_mmdb = @import("mmdb/mmdb.zig");
const embeded = @embedFile("GeoLite2-City.mmdb");

const MMDBFile = mmdb_mmdb.MMDBFile;

const enable_assertions = false;

pub fn main() !void {

    // The allocator is only necessary for a couple of strings in the metadata
    // structure. So we can keep it limited (or skip that parsing altogether).
    var buffer: [2 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buffer);

    var mmdb = try mmdb_mmdb.MMDBFile.init(embeded, allocator.allocator(), enable_assertions);
    defer mmdb.deinit();

    var stdout = io.bufferedWriter(io.getStdOut().writer());
    defer stdout.flush() catch {};
    var stderr = io.bufferedWriter(io.getStdErr().writer());
    defer stderr.flush() catch {};

    try mmdb.print(stdout.writer());
    stdout.flush() catch {};

    // try mmdbfile.lookupIpV4([_]u8{ 168, 197, 202, 44 }, stdout.writer());
    //

    // var offset = try mmdbfile.writeData(mmdbfile.nodes_offset, stdout.writer());
    // var offset = try mmdbfile.writeData(53162222, stdout.writer());
    // for (0..1000000) |_| {
    //     defer stdout.flush() catch {};
    //     try stdout.writer().print("\n" ++ "*" ** 80 ++ "\n", .{});
    //     try stdout.writer().print("* {d}\n", .{offset});
    //     try stdout.writer().print("*" ** 80 ++ "\n", .{});
    //     offset = try mmdbfile.writeData(offset, stdout.writer());
    // }

    const host = "127.0.0.1";
    const port = 8080;
    const address = try std.net.Address.resolveIp(host, port);

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    try stdout.writer().print("\n\n" ++ "-" ** 80 ++ "\n", .{});
    try stdout.writer().print("Started listening on {any}... (CTRL+C to stop)\n", .{address});
    stdout.flush() catch {};

    while (true) {
        const connection = try listener.accept();

        dispatchConnection(connection, mmdb) catch |e| {
            try stderr.writer().print("An unexpected error happened while listening to connection: {s}\n", .{@errorName(e)});
        };
    }
}

fn dispatchConnection(connection: std.net.Server.Connection, mmdb: MMDBFile) !void {
    // We own the connection now, we close it once we're done.
    defer connection.stream.close();

    var request_buff = [_]u8{undefined} ** 1024;
    var response_buff = [_]u8{undefined} ** 1024;

    var server = std.http.Server.init(connection, &request_buff);
    var request = try server.receiveHead();

    std.debug.print("{} {s} {}\n", .{ request.head.method, request.head.target, request.head.version });

    const ipv4_prefix = "/ipv4/";
    const ipv6_prefix = "/ipv6/";

    if (std.mem.startsWith(u8, request.head.target, ipv4_prefix)) {
        const parsed = parseIpV4(request.head.target[ipv4_prefix.len..]) catch {
            try request.respond("Invalid format", .{ .status = .bad_request });
            return error.BadRequest;
        };

        var response = request.respondStreaming(.{
            .send_buffer = &response_buff,
            .respond_options = .{
                .extra_headers = &[_]std.http.Header{.{
                    .name = "Content-Type",
                    .value = "application/json",
                }},
            },
        });

        const start = @divTrunc(std.time.nanoTimestamp(), 1000);
        try mmdb.lookupIpV4(parsed, response.writer());
        std.debug.print("Took: {d} μs \n", .{@divTrunc(std.time.nanoTimestamp(), 1000) - start});

        try response.end();
    } else if (std.mem.startsWith(u8, request.head.target, ipv6_prefix)) {
        const parsed = parseIpV6(request.head.target[ipv6_prefix.len..]) catch {
            try request.respond("Invalid format", .{ .status = .bad_request });
            return error.BadRequest;
        };

        var response = request.respondStreaming(.{
            .send_buffer = &response_buff,
            .respond_options = .{
                .extra_headers = &[_]std.http.Header{.{
                    .name = "Content-Type",
                    .value = "application/json",
                }},
            },
        });

        const start = @divTrunc(std.time.nanoTimestamp(), 1000);
        try mmdb.lookupIpV6(parsed, response.writer());
        std.debug.print("Took: {d} μs \n", .{@divTrunc(std.time.nanoTimestamp(), 1000) - start});

        try response.end();
    } else {
        try request.respond("Unknown target", .{ .status = .bad_request });
        return error.BadRequest;
    }
}

fn parseIpV4(str: []const u8) ![4]u8 {
    const a = try std.net.Address.parseIp4(str, 0);
    const b = std.mem.asBytes(&a.in.sa.addr);
    return b.*;
}

fn parseIpV6(str: []const u8) ![16]u8 {
    const a = try std.net.Address.parseIp6(str, 0);
    return a.in6.sa.addr;
}

test {
    _ = mmdb_mmdb;
}
