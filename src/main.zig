// GeoIP2-zig
// HTTP server with MaxMind MMDB geolocation lookup
// Endpoints: /ipv4/<ip> and /ipv6/<ip>.

const std = @import("std");
const Io = std.Io;
const zio = @import("zio");
const mmdb = @import("mmdb/mmdb.zig");
const MMDBFile = mmdb.MMDBFile;

// Embed the MaxMind database file at compile time.
const embedded = @embedFile("GeoLite2-City.mmdb");

// All runtime memory is fixed-size. The zio runtime heap holds executor lists,
// task-pool slabs, and thread-pool state; the connection slots below are the
// only per-request buffers. Budget: 2 MiB heap + 256 slots x 16 KiB = 6 MiB.
const runtime_heap_bytes = 2 << 20; // 2 MiB
const max_concurrent_connections = 256;
const max_request_bytes = 8 * 1024; // also caps the HTTP request head size
const max_response_bytes = 4 * 1024;
const max_body_bytes = 4 * 1024;

/// Fixed pool of per-connection buffers. Claiming a slot bounds the number of
/// concurrent connections, their fibers, and their memory. A slot is claimed by
/// the accept fiber and released by the connection fiber when it exits.
const Connections = struct {
    const slots_per_word = 64;
    const num_words = max_concurrent_connections / slots_per_word;
    comptime {
        std.debug.assert(max_concurrent_connections % slots_per_word == 0);
    }

    const Slot = struct {
        request_buffer: [max_request_bytes]u8 = undefined,
        response_buffer: [max_response_bytes]u8 = undefined,
        body_buffer: [max_body_bytes]u8 = undefined,
    };

    used_words: [num_words]std.atomic.Value(u64) = @splat(.init(0)),
    slots: [max_concurrent_connections]Slot = @splat(.{}),

    fn claim(self: *Connections) ?usize {
        for (&self.used_words, 0..) |*word, word_index| {
            var used = word.load(.acquire);
            while (used != ~@as(u64, 0)) {
                const bit: u6 = @intCast(@ctz(~used));
                const desired = used | (@as(u64, 1) << bit);
                if (word.cmpxchgWeak(used, desired, .acq_rel, .acquire) == null)
                    return word_index * slots_per_word + bit;
                used = word.load(.acquire);
            }
        }
        return null;
    }

    fn release(self: *Connections, index: usize) void {
        const word = &self.used_words[index / slots_per_word];
        const bit: u6 = @intCast(index % slots_per_word);
        _ = word.fetchAnd(~(@as(u64, 1) << bit), .release);
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

    // Print help and exit if requested.
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

    // Fixed allocator sized for parsing the MMDB header metadata.
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    // Load and parse the embedded MMDB database.
    const start_mmdb = getTimeMicros();
    var mmdb_file = try mmdb.MMDBFile.init(embedded, fba.allocator());
    defer mmdb_file.deinit();
    const mmdb_usecs = getTimeMicros() - start_mmdb;

    // Write database metadata to stdout.
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try mmdb_file.print(stdout);
    try stdout.print("\n\n--------------------------------------------------------------------------------\n", .{});
    try stdout.flush();

    // Create TCP server socket and start listening.
    const address = try Io.net.IpAddress.parse(config.host, config.port);
    const start_server = getTimeMicros();
    var server = try address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 512,
    });
    defer server.deinit(io);
    const server_usecs = getTimeMicros() - start_server;
    const total_usecs = mmdb_usecs + server_usecs;

    // Print initialization timing information.
    try stdout.print("Init: MMDB={d}μs Server={d}μs Total={d}μs\n", .{
        mmdb_usecs,
        server_usecs,
        total_usecs,
    });
    try stdout.print("Started listening on {s}:{d}... (CTRL+C to stop)\n", .{ config.host, config.port });
    try stdout.flush();

    // Create an async group for handling multiple concurrent connections.
    var conns: Io.Group = .init;
    var connections: Connections = .{};

    // Accept connections in a dedicated fiber so a shutdown signal can cancel
    // it while it blocks in accept.
    var acceptor: Io.Group = .init;
    acceptor.async(io, acceptLoop, .{ io, &server, &mmdb_file, &conns, &connections });

    // Wait for SIGINT or SIGTERM, then stop accepting and cancel connection
    // handlers: idle keep-alive connections would wait forever.
    waitForSignal();
    acceptor.cancel(io);
    conns.cancel(io);

    // Report how much of the fixed runtime heap is in use at shutdown.
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
        const index = connections.claim() orelse {
            rejectBusy(io, stream);
            continue;
        };
        conns.async(io, handleConnection, .{ io, stream, mmdb_file, connections, index });
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

    // Create reader/writer interfaces for the stream. The counting writer sits
    // between the HTTP server and the stream writer so each response can be
    // measured in bytes and in write time.
    var reader = stream.reader(io, &slot.request_buffer);
    var writer = stream.writer(io, &slot.response_buffer);
    var count_buffer: [64]u8 = undefined;
    var counting: CountingWriter = .{
        .io = io,
        .child = &writer.interface,
        .interface = .{
            .buffer = &count_buffer,
            .vtable = &.{ .drain = CountingWriter.drain, .flush = CountingWriter.flush, .rebase = CountingWriter.rebase },
        },
    };

    // Initialize HTTP server with our reader/writer.
    var http_server = std.http.Server.init(&reader.interface, &counting.interface);

    while (true) {
        // Receive and parse HTTP request. The request buffer size caps the
        // head; an oversize head ends the connection with 431 (RFC 6585).
        // The read itself is not timed: a keep-alive connection blocks here
        // until the client sends the next request, so the wait is client
        // think time, not server work.
        var request = http_server.receiveHead() catch |err| {
            if (err == error.HttpHeadersOversize) {
                writer.interface.writeAll(response_431) catch {};
                writer.interface.flush() catch {};
            }
            return;
        };

        const bytes_before = counting.written;
        counting.write_ns = 0;

        const start = Io.Timestamp.now(io, .awake);
        var record: LogRecord = .{
            .total_ns = 0,
            .write_ns = 0,
            .bytes_in = request.head_buffer.len,
            .bytes_out = 0,
        };

        const status = serveRequest(&request, mmdb_file, slot) catch |err| {
            record.err_name = @errorName(err);
            record.sample(io, start, &counting, bytes_before);
            logRequest(io, &request, record);
            return;
        };
        record.status = status;
        record.sample(io, start, &counting, bytes_before);
        logRequest(io, &request, record);

        if (!request.head.keep_alive) return;
    }
}

/// Writer that forwards to the connection writer and records the response bytes
/// and the time spent moving them. The clock reads in `drain`, `flush`, and
/// `rebase` cover the copies into the connection buffer and the socket writes.
const CountingWriter = struct {
    io: Io,
    child: *Io.Writer,
    written: u64 = 0,
    write_ns: i96 = 0,
    interface: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("interface", w));

        // Buffered bytes go first, then the new data.
        const buffered = w.buffered();
        w.end = 0;
        self.written += buffered.len;
        try self.forward(buffered);
        for (data, 0..) |bytes, index| {
            const repeats = if (index + 1 == data.len) splat else 1;
            self.written += bytes.len * repeats;
            for (0..repeats) |_| try self.forward(bytes);
        }
        return Io.Writer.countSplat(data, splat);
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("interface", w));
        try Io.Writer.defaultFlush(w);

        const start = Io.Timestamp.now(self.io, .awake);
        defer self.write_ns += Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds;
        try self.child.flush();
    }

    /// The buffer is fixed, so a larger contiguous request cannot be satisfied.
    fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("interface", w));
        if (preserve + capacity > w.buffer.len) return error.WriteFailed;

        // Forward the bytes that are not preserved, then move the tail down.
        const keep = @min(preserve, w.end);
        const flushable = w.end - keep;
        self.written += flushable;
        try self.forward(w.buffer[0..flushable]);
        std.mem.copyForwards(u8, w.buffer[0..keep], w.buffer[flushable..w.end]);
        w.end = keep;
    }

    fn forward(self: *CountingWriter, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const start = Io.Timestamp.now(self.io, .awake);
        defer self.write_ns += Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds;
        try self.child.writeAll(bytes);
    }
};

/// Measured values for one access-log line.
const LogRecord = struct {
    status: ?std.http.Status = null,
    err_name: ?[]const u8 = null,
    /// Request handling plus response write. Excludes the wait for the client.
    total_ns: i96,
    /// Time inside the response writer, including the socket writes.
    write_ns: i96,
    bytes_in: usize,
    bytes_out: u64,

    fn sample(self: *LogRecord, io: Io, start: Io.Timestamp, counting: *const CountingWriter, bytes_before: u64) void {
        self.total_ns = Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
        self.write_ns = counting.write_ns;
        self.bytes_out = counting.written - bytes_before;
    }
};

/// Write one access-log line to stderr.
///
/// The line is `<UTC time> <method> <target> <version> <status> <total>
/// in=<bytes> out=<bytes> write=<time>`.
/// A request that fails before a response is sent shows `-` for the status,
/// followed by the Zig error name.
fn logRequest(io: Io, request: *std.http.Server.Request, record: LogRecord) void {
    // Split the wall clock into calendar fields for an ISO 8601 UTC stamp.
    const now_us = Io.Timestamp.now(io, .real).toMicroseconds();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@divFloor(now_us, 1_000_000)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = std.fmt.bufPrint(&timestamp_buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        @as(u32, @intCast(@divTrunc(@mod(now_us, 1_000_000), 1000))),
    }) catch return;

    var status_buffer: [4]u8 = undefined;
    const status_text = if (record.status) |s|
        std.fmt.bufPrint(&status_buffer, "{d}", .{@backingInt(s)}) catch "-"
    else
        "-";

    std.debug.print("{s} {s} {s} {s} {s} {d}μs in={d}B out={d}B write={d}μs{s}{s}\n", .{
        timestamp,
        @tagName(request.head.method),
        request.head.target,
        @tagName(request.head.version),
        status_text,
        @divTrunc(record.total_ns, 1000),
        record.bytes_in,
        record.bytes_out,
        @divTrunc(record.write_ns, 1000),
        if (record.err_name == null) "" else " ",
        record.err_name orelse "",
    });
}

/// Send a complete response and return its status for the access log.
fn respond(
    request: *std.http.Server.Request,
    content: []const u8,
    status: std.http.Status,
) !std.http.Status {
    try request.respond(content, .{ .status = status });
    return status;
}

/// Serve a single request: performs IP lookup and returns JSON response.
/// Any failure ends the connection.
fn serveRequest(
    request: *std.http.Server.Request,
    mmdb_file: *MMDBFile,
    slot: *Connections.Slot,
) !std.http.Status {
    // All endpoints are GET-only. An unread body would desync the next
    // request on a keep-alive connection, so reject requests that carry one.
    if (request.head.content_length != null or request.head.transfer_encoding == .chunked) {
        request.respond("Request body not allowed", .{ .status = .bad_request }) catch {};
        return error.BodyRejected;
    }

    // Fast path for favicon.ico requests - return empty response.
    if (std.mem.eql(u8, request.head.target, "/favicon.ico"))
        return respond(request, "", .no_content);

    // Health check endpoint.
    if (std.mem.eql(u8, request.head.target, "/health"))
        return respond(request, "OK", .ok);

    // Detect IP version from URL path, return 400 if unknown.
    const ip = IpVersion.detect(request.head.target) catch {
        return respond(request, "Unknown target", .bad_request);
    };

    // Parse the IP address string into 16-byte array
    // IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d).
    const address = ip.parse() catch {
        return respond(request, "Invalid format", .bad_request);
    };

    // Fast probe: check if IP exists in database before streaming response.
    if (!mmdb_file.lookupIpV6Probe(address))
        return respond(request, "IP not found in database", .not_found);

    // Use streaming response - writes headers first, then body.
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

    // Write JSON directly to streaming body (single underlying stream).
    mmdb_file.lookupIpV6(address, &body_writer.writer) catch |e| {
        std.debug.print("lookupIpV6 error: {}\n", .{e});
        return e;
    };

    try body_writer.end();
    return .ok;
}

/// IP version union type for handling both IPv4 and IPv6.
/// Each variant carries the address string from the request target.
const IpVersion = union(enum) {
    ipv4: []const u8,
    ipv6: []const u8,

    /// Detect IP version from HTTP request target path and capture the address.
    /// Returns error.UnknownTarget if path doesn't match /ipv4/ or /ipv6/.
    fn detect(target: []const u8) !IpVersion {
        if (std.mem.startsWith(u8, target, "/ipv4/")) return .{ .ipv4 = target["/ipv4/".len..] };
        if (std.mem.startsWith(u8, target, "/ipv6/")) return .{ .ipv6 = target["/ipv6/".len..] };
        return error.UnknownTarget;
    }

    /// Parse the captured address string into a 16-byte array.
    /// IPv4 addresses are converted to IPv6-mapped format (::ffff:a.b.c.d).
    fn parse(self: IpVersion) ![16]u8 {
        return switch (self) {
            .ipv4 => |str| brk: {
                const addr4 = try std.Io.net.IpAddress.parseIp4(str, 0);
                break :brk [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, addr4.ip4.bytes[0], addr4.ip4.bytes[1], addr4.ip4.bytes[2], addr4.ip4.bytes[3] };
            },
            .ipv6 => |str| (try std.Io.net.IpAddress.parseIp6(str, 0)).ip6.bytes,
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

////////////////////////////////////////////////////////////////////////////////

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
    try std.testing.expectEqualStrings("8.8.8.8", result.ipv4);
}

test "IpVersion.detect ipv6" {
    const result = try IpVersion.detect("/ipv6/2001:4860:4860::8888");
    try std.testing.expectEqualStrings("2001:4860:4860::8888", result.ipv6);
}

test "IpVersion.detect unknown target" {
    try std.testing.expectError(error.UnknownTarget, IpVersion.detect("/health"));
}

test "IpVersion.detect root path" {
    try std.testing.expectError(error.UnknownTarget, IpVersion.detect("/"));
}

test "IpVersion.parse IPv4 to IPv6-mapped" {
    const ip = try IpVersion.detect("/ipv4/8.8.8.8");
    const result = try ip.parse();
    try std.testing.expectEqual([16]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xff, 0x08, 0x08, 0x08, 0x08,
    }, result);
}

test "IpVersion.parse IPv4 invalid" {
    const ip = try IpVersion.detect("/ipv4/invalid");
    try std.testing.expectError(error.InvalidCharacter, ip.parse());
}

test "IpVersion.parse IPv6" {
    const ip = try IpVersion.detect("/ipv6/::1");
    const result = try ip.parse();
    try std.testing.expectEqual(@as(u8, 1), result[15]);
    try std.testing.expectEqual(@as(u8, 0), result[0]);
    try std.testing.expectEqual(@as(u8, 0), result[14]);
}
