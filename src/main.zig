// GeoIP2-zig
// HTTP server with MaxMind MMDB geolocation lookup
// Endpoints: /ipv4/<ip> and /ipv6/<ip>

const std = @import("std");
const Io = std.Io;
const zio = @import("zio");
const mmdb = @import("mmdb/mmdb.zig");
const MMDBFile = mmdb.MMDBFile;

// Route std.log and std.debug.print through the zio runtime so logging
// never blocks the event loop
pub const std_options_debug_io = zio.debug_io;

// Embed the MaxMind database file at compile time
const embedded = @embedFile("GeoLite2-City.mmdb");
const enable_assertions = @import("builtin").mode == .debug;

// All runtime memory is fixed-size. The zio runtime heap holds executor lists,
// task-pool slabs, and thread-pool state; it is sized for the worst case of
// max_concurrent_connections live fibers. The connection slots below are the
// only per-request buffers.
const runtime_heap_bytes = 1 << 20; // 1 MiB
const max_concurrent_connections = 64;
const max_request_bytes = 1024; // also caps the HTTP request head size
const max_response_bytes = 1024;
const max_body_bytes = 1024;

/// Fixed pool of per-connection buffers. Claiming a slot bounds the number of
/// concurrent connections, their fibers, and their memory. A slot is claimed by
/// the accept fiber and released by the connection fiber when it exits.
const Connections = struct {
    const Slot = struct {
        request_buffer: [max_request_bytes]u8 = undefined,
        response_buffer: [max_response_bytes]u8 = undefined,
        body_buffer: [max_body_bytes]u8 = undefined,
    };

    used_bits: std.atomic.Value(u64) = .init(0),
    slots: [max_concurrent_connections]Slot = @splat(.{}),

    fn claim(self: *Connections) ?usize {
        var used = self.used_bits.load(.acquire);
        while (used != ~@as(u64, 0)) {
            const index = @ctz(~used);
            const desired = used | (@as(u64, 1) << @intCast(index));
            used = self.used_bits.cmpxchgWeak(used, desired, .acq_rel, .acquire) orelse return index;
        }
        return null;
    }

    fn release(self: *Connections, index: usize) void {
        _ = self.used_bits.fetchAnd(~(@as(u64, 1) << @intCast(index)), .release);
    }
};

/// Main entry point for the GeoIP2 server.
/// Initializes the zio event-driven runtime on a fixed heap, loads the MMDB
/// database, binds to the HTTP port, and starts accepting connections.
pub fn main(init: std.process.Init.Minimal) !void {
    var runtime_heap: [runtime_heap_bytes]u8 = undefined;
    var runtime_fba = std.heap.FixedBufferAllocator.init(&runtime_heap);
    var rt: zio.Runtime = undefined;
    try rt.initStatic(runtime_fba.threadSafeAllocator(), .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    const config = parseArgs(init.args);

    // Print help and exit if requested
    if (config.help) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer = Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        stderr.print("Usage: geoip-zig [OPTIONS]\n", .{}) catch {};
        stderr.print("  -h, --host HOST    Bind to host (default: 127.0.0.1)\n", .{}) catch {};
        stderr.print("  -p, --port PORT    Bind to port (default: 8080)\n", .{}) catch {};
        stderr.print("      --help         Show this help\n", .{}) catch {};
        stderr.flush() catch {};
        return error.Success;
    }

    // Fixed allocator sized for parsing the MMDB header metadata
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    // Load and parse the embedded MMDB database
    const start_mmdb = getTimeMicros();
    var mmdb_file = try mmdb.MMDBFile.init(embedded, fba.allocator(), enable_assertions);
    defer mmdb_file.deinit();
    const mmdb_usecs = getTimeMicros() - start_mmdb;

    // Write database metadata to stdout
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try mmdb_file.print(stdout);
    try stdout.print("\n\n--------------------------------------------------------------------------------\n", .{});
    try stdout.flush();

    // Create TCP server socket and start listening
    const address = try Io.net.IpAddress.parse(config.host, config.port);
    const start_server = getTimeMicros();
    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);
    const server_usecs = getTimeMicros() - start_server;
    const total_usecs = mmdb_usecs + server_usecs;

    // Print initialization timing information
    try stdout.print("Init: MMDB={d}μs Server={d}μs Total={d}μs\n", .{
        mmdb_usecs,
        server_usecs,
        total_usecs,
    });
    try stdout.print("Started listening on {s}:{d}... (CTRL+C to stop)\n", .{ config.host, config.port });
    try stdout.flush();

    // Create an async group for handling multiple concurrent connections
    var conns: Io.Group = .init;
    var connections: Connections = .{};

    // Accept connections in a dedicated fiber so a shutdown signal can cancel
    // it while it blocks in accept
    var acceptor: Io.Group = .init;
    acceptor.async(io, acceptLoop, .{ io, &server, &mmdb_file, &conns, &connections });

    // Wait for SIGINT or SIGTERM, then stop accepting and cancel connection
    // handlers: idle keep-alive connections would wait forever
    waitForSignal();
    acceptor.cancel(io);
    conns.cancel(io);

    // Report how much of the fixed runtime heap is in use at shutdown
    try stdout.print("Runtime heap in use: {d} of {d} bytes\n", .{
        runtime_fba.end_index,
        runtime_heap.len,
    });
    try stdout.flush();
}

/// Suspend the calling fiber until SIGINT or SIGTERM arrives.
fn waitForSignal() void {
    var sigint = zio.Signal.init(.interrupt) catch return;
    defer sigint.deinit();

    var sigterm = zio.Signal.init(.terminate) catch return;
    defer sigterm.deinit();

    _ = zio.select(.{ .sigint = &sigint, .sigterm = &sigterm }) catch {};
}

/// Accept loop: spawn a connection handler per accepted stream until canceled.
/// Connections beyond the slot pool are rejected with 503 without allocating a
/// fiber, so a connection flood cannot grow memory.
fn acceptLoop(
    io: Io,
    server: *Io.net.Server,
    mmdb_file: *MMDBFile,
    conns: *Io.Group,
    connections: *Connections,
) Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        if (connections.claim()) |index| {
            conns.async(io, handleConnection, .{ io, stream, mmdb_file, connections, index });
        } else {
            rejectBusy(io, stream);
        }
    }
}

const response_503_body = "no capacity";
const response_503 =
    "HTTP/1.1 503 Service Unavailable\r\n" ++
    "connection: close\r\n" ++
    "content-length: 11\r\n\r\n" ++
    response_503_body;

const response_431_body = "too large\n";
const response_431 =
    "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
    "connection: close\r\n" ++
    "content-length: 10\r\n\r\n" ++
    response_431_body;

comptime {
    std.debug.assert(response_503_body.len == 11);
    std.debug.assert(response_431_body.len == 10);
}

/// Respond 503 on the accept fiber itself: no slot or fiber is available.
fn rejectBusy(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(response_503) catch return;
    writer.interface.flush() catch {};
}

/// Handle a single HTTP connection.
/// Serves requests until the client closes the connection or asks to close.
fn handleConnection(
    io: Io,
    stream: Io.net.Stream,
    mmdb_file: *MMDBFile,
    connections: *Connections,
    index: usize,
) void {
    defer stream.close(io);
    defer connections.release(index);

    const slot = &connections.slots[index];

    // Create reader/writer interfaces for the stream
    var reader = stream.reader(io, &slot.request_buffer);
    var writer = stream.writer(io, &slot.response_buffer);

    // Initialize HTTP server with our reader/writer
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        // Receive and parse HTTP request. The request buffer size caps the
        // head; an oversize head ends the connection with 431 (RFC 6585).
        var request = http_server.receiveHead() catch |err| {
            if (err == error.HttpHeadersOversize) {
                writer.interface.writeAll(response_431) catch {};
                writer.interface.flush() catch {};
            }
            return;
        };

        // Log the request to stderr
        std.debug.print("{} {s} {}\n", .{ request.head.method, request.head.target, request.head.version });

        serveRequest(&request, mmdb_file, slot) catch return;

        if (!request.head.keep_alive) return;
    }
}

/// Serve a single request: performs IP lookup and returns JSON response.
/// Any failure ends the connection.
fn serveRequest(
    request: *std.http.Server.Request,
    mmdb_file: *MMDBFile,
    slot: *Connections.Slot,
) !void {
    // All endpoints are GET-only. An unread body would desync the next
    // request on a keep-alive connection, so reject requests that carry one.
    if (request.head.content_length != null or request.head.transfer_encoding == .chunked) {
        request.respond("Request body not allowed", .{ .status = .bad_request }) catch {};
        return error.BodyRejected;
    }

    // Fast path for favicon.ico requests - return empty response
    if (std.mem.eql(u8, request.head.target, "/favicon.ico")) {
        return request.respond("", .{ .status = .no_content });
    }

    // Health check endpoint
    if (std.mem.eql(u8, request.head.target, "/health")) {
        return request.respond("OK", .{ .status = .ok });
    }

    // Detect IP version from URL path, return 400 if unknown
    const ip_prefix = IpVersion.detect(request.head.target) catch {
        return request.respond("Unknown target", .{ .status = .bad_request });
    };

    // Parse the IP address string into 16-byte array
    // IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d)
    const address: [16]u8 = ip_prefix.parse(request.head.target) catch {
        return request.respond("Invalid format", .{ .status = .bad_request });
    };

    // Fast probe: check if IP exists in database before streaming response
    if (!mmdb_file.lookupIpV6Probe(address)) {
        return request.respond("IP not found in database", .{ .status = .not_found });
    }

    // Use streaming response - writes headers first, then body
    var body_writer = request.respondStreaming(&slot.body_buffer, .{
        .respond_options = .{
            .extra_headers = &[_]std.http.Header{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        },
    }) catch {
        return error.ResponseFailed;
    };

    // Write JSON directly to streaming body (single underlying stream)
    mmdb_file.lookupIpV6(address, &body_writer.writer) catch |e| {
        std.debug.print("lookupIpV6 error: {}\n", .{e});
        return e;
    };

    try body_writer.end();
}

/// IP version union type for handling both IPv4 and IPv6.
/// Encapsulates URL parsing and IP address conversion.
const IpVersion = union(enum) {
    ipv4,
    ipv6,

    /// Detect IP version from HTTP request target path.
    /// Returns error.UnknownTarget if path doesn't match /ipv4/ or /ipv6/.
    fn detect(target: []const u8) !IpVersion {
        if (std.mem.startsWith(u8, target, "/ipv4/")) return .ipv4;
        if (std.mem.startsWith(u8, target, "/ipv6/")) return .ipv6;
        return error.UnknownTarget;
    }

    /// Get the URL prefix for this IP version.
    fn prefix(self: IpVersion) []const u8 {
        return switch (self) {
            .ipv4 => "/ipv4/",
            .ipv6 => "/ipv6/",
        };
    }

    /// Extract the IP address string from the URL target.
    /// e.g., "/ipv4/8.8.8.8" -> "8.8.8.8"
    fn path(self: IpVersion, target: []const u8) []const u8 {
        return target[self.prefix().len..];
    }

    /// Parse the IP address string into a 16-byte array.
    /// IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d).
    /// Returns error.ParseFailed if the string is not a valid IP address.
    fn parse(self: IpVersion, target: []const u8) ![16]u8 {
        return switch (self) {
            .ipv4 => brk: {
                const addr4 = try std.Io.net.IpAddress.parseIp4(self.path(target), 0);
                break :brk [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, addr4.ip4.bytes[0], addr4.ip4.bytes[1], addr4.ip4.bytes[2], addr4.ip4.bytes[3] };
            },
            .ipv6 => brk: {
                const addr6 = try std.Io.net.IpAddress.parseIp6(self.path(target), 0);
                break :brk addr6.ip6.bytes;
            },
        };
    }
};

/// Get current time in microseconds using clock_gettime.
/// Used for performance timing of operations.
fn getTimeMicros() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// Parse command line arguments.
/// Returns host, port, and help flag.
fn parseArgs(args: std.process.Args) struct { host: []const u8, port: u16, help: bool } {
    var iter = std.process.Args.Iterator.init(args);
    defer iter.deinit();

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;
    var help = false;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--host")) {
            if (iter.next()) |val| {
                host = val;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (iter.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-?")) {
            help = true;
        }
    }
    return .{ .host = host, .port = port, .help = help };
}

test "Connections claim exhausts pool then release reclaims" {
    var connections: Connections = .{};
    var claimed: [max_concurrent_connections]usize = undefined;
    for (0..claimed.len) |i| {
        claimed[i] = connections.claim() orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(null, connections.claim());
    connections.release(claimed[7]);
    try std.testing.expectEqual(claimed[7], connections.claim());
}

test "IpVersion.detect ipv4" {
    const result = try IpVersion.detect("/ipv4/8.8.8.8");
    try std.testing.expectEqual(IpVersion.ipv4, result);
}

test "IpVersion.detect ipv6" {
    const result = try IpVersion.detect("/ipv6/2001:4860:4860::8888");
    try std.testing.expectEqual(IpVersion.ipv6, result);
}

test "IpVersion.detect unknown target" {
    const result = IpVersion.detect("/health");
    try std.testing.expectError(error.UnknownTarget, result);
}

test "IpVersion.detect root path" {
    const result = IpVersion.detect("/");
    try std.testing.expectError(error.UnknownTarget, result);
}

test "IpVersion.path extracts IP correctly" {
    const ipv4: IpVersion = .ipv4;
    const ipv6: IpVersion = .ipv6;
    try std.testing.expectEqualStrings("8.8.8.8", ipv4.path("/ipv4/8.8.8.8"));
    try std.testing.expectEqualStrings("2001:4860:4860::8888", ipv6.path("/ipv6/2001:4860:4860::8888"));
}

test "IpVersion.parse IPv4 to IPv6-mapped" {
    const result = try IpVersion.parse(IpVersion.ipv4, "/ipv4/8.8.8.8");
    try std.testing.expectEqual([16]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xff, 0x08, 0x08, 0x08, 0x08,
    }, result);
}

test "IpVersion.parse IPv4 invalid" {
    const result = IpVersion.parse(IpVersion.ipv4, "/ipv4/invalid");
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "IpVersion.parse IPv6" {
    const result = try IpVersion.parse(IpVersion.ipv6, "/ipv6/::1");
    try std.testing.expectEqual(@as(u8, 1), result[15]);
    try std.testing.expectEqual(@as(u8, 0), result[0]);
    try std.testing.expectEqual(@as(u8, 0), result[14]);
}
