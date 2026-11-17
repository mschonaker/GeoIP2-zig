// GeoIP2-zig
// Minimal MCP (Model Context Protocol) endpoint over HTTP.
// Transport: stateless JSON-RPC 2.0 POST at /mcp.
// Tools: lookup_ipv4 and lookup_ipv6. The MMDB JSON is embedded as a text
// content block and streamed straight from the writer.

const std = @import("std");
const json = std.json;
const mmdb = @import("mmdb/mmdb.zig");

const max_body_bytes = 4 * 1024;

const default_protocol_version = "2024-11-05";
const invalid_request = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}";

pub fn handle(
    request: *std.http.Server.Request,
    mmdb_file: *mmdb.MMDBFile,
    io_buf: []u8,
) !std.http.Status {
    if (request.head.method != .POST) {
        request.head.keep_alive = false;
        return respondJson(request, .method_not_allowed, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Method not allowed\"}}");
    }

    var body_buf: [max_body_bytes + 1]u8 = undefined;
    const body = readBody(request, io_buf, &body_buf) catch {
        request.head.keep_alive = false;
        return respondJson(request, .bad_request, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Invalid body\"}}");
    };

    var parse_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const root = json.parseFromSliceLeaky(json.Value, fba.allocator(), body, .{}) catch {
        return respondJson(request, .bad_request, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    };

    if (root != .object) {
        return respondJson(request, .bad_request, invalid_request);
    }

    const id = root.object.get("id");
    const version_val = root.object.get("jsonrpc") orelse
        return respondJson(request, .bad_request, invalid_request);
    if (version_val != .string or !std.mem.eql(u8, version_val.string, "2.0"))
        return respondJson(request, .bad_request, invalid_request);

    const method_val = root.object.get("method") orelse
        return respondJson(request, .bad_request, invalid_request);
    if (method_val != .string)
        return respondJson(request, .bad_request, invalid_request);
    const method = method_val.string;

    // Notifications carry no id. The Streamable HTTP transport answers 202.
    if (id == null) {
        try request.respond("", .{ .status = .accepted });
        return .accepted;
    }

    if (std.mem.eql(u8, method, "initialize")) {
        const version = requestedProtocolVersion(root.object) orelse default_protocol_version;
        var resp_buf: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&resp_buf);
        try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeJsonValue(&out, id);
        try out.writeAll(",\"result\":{\"protocolVersion\":");
        try writeJsonString(&out, version);
        try out.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"geoip-zig\",\"version\":\"0.1.0\"}}}");
        return respondJson(request, .ok, resp_buf[0..out.end]);
    }

    if (std.mem.eql(u8, method, "ping")) {
        return respondResult(request, id, "{}");
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        return respondResult(request, id, tools_list);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        return handleToolCall(request, mmdb_file, root.object, id, io_buf);
    }

    return respondError(request, id, -32601, "Method not found");
}

fn requestedProtocolVersion(root: json.ObjectMap) ?[]const u8 {
    const params_val = root.get("params") orelse return null;
    if (params_val != .object) return null;
    const version_val = params_val.object.get("protocolVersion") orelse return null;
    if (version_val != .string) return null;
    return version_val.string;
}

const tools_list =
    "{\"tools\":[" ++
    "{\"name\":\"lookup_ipv4\",\"description\":\"Look up geolocation for an IPv4 address\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"ip\":{\"type\":\"string\",\"description\":\"IPv4 address\"}},\"required\":[\"ip\"]}}," ++
    "{\"name\":\"lookup_ipv6\",\"description\":\"Look up geolocation for an IPv6 address\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"ip\":{\"type\":\"string\",\"description\":\"IPv6 address\"}},\"required\":[\"ip\"]}}" ++
    "]}";

/// Read the request body into `out`. `io_buf` is the reader transfer buffer.
/// Returns at most `max_body_bytes` bytes; longer bodies are rejected so the
/// connection is closed instead of drained.
fn readBody(
    request: *std.http.Server.Request,
    io_buf: []u8,
    out: []u8,
) ![]const u8 {
    const reader = request.readerExpectContinue(io_buf) catch return error.ReadFailed;

    if (request.head.transfer_encoding == .none) {
        const cl = request.head.content_length orelse return "";
        if (cl > max_body_bytes) return error.StreamTooLong;
        if (cl == 0) return "";
    }

    var total: usize = 0;
    while (total < out.len) {
        const n = reader.readSliceShort(out[total..]) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    if (total > max_body_bytes) return error.StreamTooLong;
    return out[0..total];
}

fn handleToolCall(
    request: *std.http.Server.Request,
    mmdb_file: *mmdb.MMDBFile,
    root: json.ObjectMap,
    id: ?json.Value,
    io_buf: []u8,
) !std.http.Status {
    const params_val = root.get("params") orelse return respondError(request, id, -32602, "Invalid params");
    if (params_val != .object) return respondError(request, id, -32602, "Invalid params");
    const params = params_val.object;

    const name_val = params.get("name") orelse return respondError(request, id, -32602, "Invalid params");
    if (name_val != .string) return respondError(request, id, -32602, "Invalid params");
    const name = name_val.string;

    const args_val = params.get("arguments") orelse return respondError(request, id, -32602, "Invalid params");
    if (args_val != .object) return respondError(request, id, -32602, "Invalid params");
    const args = args_val.object;

    const ip_val = args.get("ip") orelse return respondError(request, id, -32602, "Missing ip");
    if (ip_val != .string) return respondError(request, id, -32602, "Invalid ip");
    const ip_str = ip_val.string;

    const is_v4 = std.mem.eql(u8, name, "lookup_ipv4");
    const is_v6 = std.mem.eql(u8, name, "lookup_ipv6");
    if (!is_v4 and !is_v6) return respondError(request, id, -32602, "Unknown tool");

    const addr = if (is_v4) parseIpv4(ip_str) else parseIpv6(ip_str);
    const address = addr catch return respondToolError(request, id, "Invalid IP format");

    if (!mmdb_file.lookupIpV6Probe(address))
        return respondToolError(request, id, "IP not found in database");

    var body = request.respondStreaming(io_buf, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        },
    }) catch return error.ResponseFailed;

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&body.writer, id);
    try body.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");

    var escape_buf: [512]u8 = undefined;
    var escape = EscapingWriter.init(&escape_buf, &body.writer);
    mmdb_file.lookupIpV6(address, &escape.interface, null) catch |err| return err;
    try escape.interface.flush();

    try body.writer.writeAll("\"}]}}");
    try body.end();
    return .ok;
}

/// Writer adapter that escapes bytes as a JSON string while forwarding them.
/// The MMDB JSON is streamed through this adapter, so the response never sits
/// in a single buffer.
const EscapingWriter = struct {
    child: *std.Io.Writer,
    interface: std.Io.Writer,

    fn init(buffer: []u8, child: *std.Io.Writer) EscapingWriter {
        return .{
            .child = child,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EscapingWriter = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffered();
        w.end = 0;
        try self.escape(buffered);
        for (data, 0..) |bytes, index| {
            const repeats = if (index + 1 == data.len) splat else 1;
            for (0..repeats) |_| try self.escape(bytes);
        }
        return std.Io.Writer.countSplat(data, splat);
    }

    fn escape(self: *EscapingWriter, bytes: []const u8) !void {
        try writeEscaped(self.child, bytes);
    }
};

fn parseIpv4(str: []const u8) ![16]u8 {
    const addr4 = try std.Io.net.IpAddress.parseIp4(str, 0);
    return [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, addr4.ip4.bytes[0], addr4.ip4.bytes[1], addr4.ip4.bytes[2], addr4.ip4.bytes[3] };
}

fn parseIpv6(str: []const u8) ![16]u8 {
    return (try std.Io.net.IpAddress.parseIp6(str, 0)).ip6.bytes;
}

fn respondJson(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !std.http.Status {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
    return status;
}

fn respondResult(request: *std.http.Server.Request, id: ?json.Value, result_json: []const u8) !std.http.Status {
    var resp_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&resp_buf);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&out, id);
    try out.writeAll(",\"result\":");
    try out.writeAll(result_json);
    try out.writeAll("}");
    return respondJson(request, .ok, resp_buf[0..out.end]);
}

fn respondError(request: *std.http.Server.Request, id: ?json.Value, code: i32, message: []const u8) !std.http.Status {
    var resp_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&resp_buf);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&out, id);
    try out.writeAll(",\"error\":{\"code\":");
    try out.print("{d}", .{code});
    try out.writeAll(",\"message\":");
    try writeJsonString(&out, message);
    try out.writeAll("}}");
    return respondJson(request, .ok, resp_buf[0..out.end]);
}

fn respondToolError(request: *std.http.Server.Request, id: ?json.Value, message: []const u8) !std.http.Status {
    var resp_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&resp_buf);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&out, id);
    try out.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(&out, message);
    try out.writeAll("}],\"isError\":true}}");
    return respondJson(request, .ok, resp_buf[0..out.end]);
}

fn writeJsonValue(out: *std.Io.Writer, val: ?json.Value) !void {
    const v = val orelse return out.writeAll("null");
    switch (v) {
        .null => try out.writeAll("null"),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .integer => |i| try out.print("{d}", .{i}),
        .float => |f| try out.print("{d}", .{f}),
        .number_string, .string => |s| try writeJsonString(out, s),
        else => try out.writeAll("null"),
    }
}

fn writeJsonString(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    try writeEscaped(out, s);
    try out.writeByte('"');
}

fn writeEscaped(out: *std.Io.Writer, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try out.writeAll(bytes[start..i]);
            try out.writeAll(r);
            start = i + 1;
        } else if (c < 0x20) {
            if (i > start) try out.writeAll(bytes[start..i]);
            try out.print("\\u{x:0>4}", .{c});
            start = i + 1;
        }
    }
    if (start < bytes.len) try out.writeAll(bytes[start..]);
}

////////////////////////////////////////////////////////////////////////////////

test "parseIpv4 maps to IPv6 bytes" {
    const addr = try parseIpv4("8.8.8.8");
    try std.testing.expectEqual([16]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xff, 0x08, 0x08, 0x08, 0x08,
    }, addr);
    try std.testing.expectError(error.InvalidCharacter, parseIpv4("not-an-ip"));
    try std.testing.expectError(error.InvalidCharacter, parseIpv4("2001:4860:4860::8888"));
}

test "parseIpv6" {
    const addr = try parseIpv6("2001:4860:4860::8888");
    try std.testing.expectEqual(@as(u8, 0x20), addr[0]);
    try std.testing.expectEqual(@as(u8, 0x88), addr[15]);
    try std.testing.expectError(error.InvalidCharacter, parseIpv6("8.8.8.8"));
}

test "writeJsonString escapes control and quote characters" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&out, "a\"b\\c\nd\u{1}");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", buf[0..out.end]);
}
