// GeoIP2-zig - MIT License
// HTTP server with MaxMind MMDB geolocation lookup
// Endpoints: /ipv4/<ip> and /ipv6/<ip>

const std = @import("std");
const Io = std.Io;
const mmdb = @import("mmdb/mmdb.zig");
const signals = @import("signals.zig");
const MMDBFile = mmdb.MMDBFile;

// Embed the MaxMind database file at compile time
const embedded = @embedFile("GeoLite2-City.mmdb");
const enable_assertions = @import("builtin").mode == .Debug;

/// Main entry point for the GeoIP2 server.
/// Initializes the async I/O subsystem, loads the MMDB database,
/// binds to the HTTP port, and starts accepting connections.
pub fn main(init: std.process.Init.Minimal) !void {
    const io = Io.Threaded.global_single_threaded.io();

    signals.initSignals();

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

    // Fixed buffer allocator for parsing - 32KB should be enough
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
    try stdout.print("\n\n" ++ "-" ** 80 ++ "\n", .{});
    try stdout.flush();

    // Create TCP server socket and start listening
    const address = try Io.net.IpAddress.parse(config.host, config.port);
    const start_server = getTimeMicros();
    var server = try address.listen(io, .{
        .reuse_address = true,
    });
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
    var group: Io.Group = .init;

    // Main event loop: accept and handle connections
    while (!signals.isShutdownRequested()) {
        const stream = server.accept(io) catch continue;
        // Spawn async handler for each connection
        group.async(io, handleConnection, .{ io, stream, &mmdb_file });
    }

    // Wait for all pending connections to complete
    group.await(io) catch {};
}

/// Handle a single HTTP connection.
/// Parses the request, performs IP lookup, and returns JSON response.
fn handleConnection(io: Io, stream: Io.net.Stream, mmdb_file: *MMDBFile) void {
    // Ensure stream is closed when handler exits
    defer stream.close(io);

    // Single buffer for everything: read request, then write response
    var request_buffer: [1024]u8 = undefined;
    var response_buffer: [1024]u8 = undefined;

    // Create reader/writer interfaces for the stream
    var reader = stream.reader(io, &request_buffer);
    var writer = stream.writer(io, &response_buffer);

    // Initialize HTTP server with our reader/writer
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    // Receive and parse HTTP request
    var request = http_server.receiveHead() catch {
        return;
    };

    // Log the request to stderr
    std.debug.print("{} {s} {}\n", .{ request.head.method, request.head.target, request.head.version });

    // Fast path for favicon.ico requests - return empty response
    if (std.mem.eql(u8, request.head.target, "/favicon.ico")) {
        request.respond("", .{ .status = .no_content }) catch {};
        return;
    }

    // Health check endpoint
    if (std.mem.eql(u8, request.head.target, "/health")) {
        request.respond("OK", .{ .status = .ok }) catch {};
        return;
    }

    // Detect IP version from URL path, return 400 if unknown
    const ip_prefix = IpVersion.detect(request.head.target) catch {
        request.respond("Unknown target", .{ .status = .bad_request }) catch {};
        return;
    };

    // Parse the IP address string into 16-byte array
    // IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d)
    const address: [16]u8 = ip_prefix.parse(request.head.target) catch {
        request.respond("Invalid format", .{ .status = .bad_request }) catch {};
        return;
    };

    // Fast probe: check if IP exists in database before streaming response
    if (!mmdb_file.lookupIpV6Probe(address)) {
        request.respond("IP not found in database", .{ .status = .not_found }) catch {};
        return;
    }

    // Use streaming response - writes headers first, then body
    var body_buf: [1024]u8 = undefined;
    var body_writer = request.respondStreaming(&body_buf, .{
        .respond_options = .{
            .extra_headers = &[_]std.http.Header{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        },
    }) catch {
        return;
    };

    // Write JSON directly to streaming body (single underlying stream)
    mmdb_file.lookupIpV6(address, &body_writer.writer) catch |e| {
        std.debug.print("lookupIpV6 error: {}\n", .{e});
        return;
    };

    body_writer.end() catch {};
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
