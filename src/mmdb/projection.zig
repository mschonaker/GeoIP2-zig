// GeoIP2-zig
// Field projection - parses and matches "?f=" path expressions.

const std = @import("std");

pub const max_paths = 32;
pub const max_segments = 8;
pub const max_segment_bytes = 64;

pub const Error = error{InvalidProjection};

/// One requested path. The segments are slices into the spec string, so the
/// spec must outlive the projection.
pub const Path = struct {
    segments: [max_segments][]const u8,
    len: u8,
    exclude: bool,
};

/// One child of a map or array container.
pub const Child = union(enum) {
    key: []const u8,
    index: usize,
};

/// The paths that matched one container child and how they select it.
pub const Match = struct {
    paths: []const usize = &.{},
    /// An excluded path ends at the child.
    suppress: bool = false,
    /// An included path ends at the child.
    inc_term: bool = false,
    /// An included path continues below the child.
    inc_deep: bool = false,
    /// Any path continues below the child.
    deep: bool = false,
};

/// A parsed set of requested paths for one request.
pub const Projection = struct {
    paths: [max_paths]Path = undefined,
    count: usize = 0,
    /// True when at least one path is an inclusion. Without inclusions every
    /// field is selected except the excluded paths.
    has_includes: bool = false,

    /// Parse a projection spec, the value of the "?f=" query parameter.
    /// Grammar:
    ///
    ///     spec    = path ("," path)*
    ///     path    = ["!"] segment ( "." segment )*
    ///     segment = name | "*" | "(" name ( "," name )* ")"
    ///
    /// A group is only allowed as the last segment of a path and expands to
    /// one path per member. "*" matches any single key or array element.
    /// Numeric segments match array elements by index. A "!" prefix excludes
    /// the matched subtree. Exclusions win over inclusions.
    pub fn parse(spec: []const u8) Error!Projection {
        if (spec.len == 0) return error.InvalidProjection;
        var proj: Projection = .{};
        var rest = spec;
        while (true) {
            const end = topLevelComma(rest) orelse rest.len;
            try proj.addPath(rest[0..end]);
            if (end == rest.len) break;
            rest = rest[end + 1 ..];
            if (rest.len == 0) return error.InvalidProjection;
        }
        return proj;
    }

    /// Parse an HTTP query string and return the projection for the "f"
    /// parameter. Returns null when the query does not carry one. If the
    /// parameter repeats, the last value wins.
    pub fn parseQuery(query: []const u8) Error!?Projection {
        var result: ?Projection = null;
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (!std.mem.eql(u8, pair[0..eq], "f")) continue;
            result = try parse(pair[eq + 1 ..]);
        }
        return result;
    }

    /// Collect the active paths that match one child of a container that has
    /// consumed `depth` segments. The matched path indices go into `out`.
    pub fn match(
        self: *const Projection,
        active: []const usize,
        depth: usize,
        child: Child,
        out: []usize,
    ) Match {
        var m: Match = .{};
        var count: usize = 0;
        for (active) |i| {
            const path = &self.paths[i];
            const plen: usize = path.len;
            if (plen <= depth) continue;
            if (!segMatch(path.segments[depth], child)) continue;
            if (plen == depth + 1) {
                if (path.exclude) m.suppress = true else m.inc_term = true;
            } else {
                m.deep = true;
                if (!path.exclude) m.inc_deep = true;
            }
            out[count] = i;
            count += 1;
        }
        m.paths = out[0..count];
        return m;
    }

    /// Add one comma-split path, expanding a trailing group to one path per
    /// member.
    fn addPath(self: *Projection, raw: []const u8) Error!void {
        var rest = raw;
        var exclude = false;
        if (rest.len > 0 and rest[0] == '!') {
            exclude = true;
            rest = rest[1..];
        }
        var segs: [max_segments][]const u8 = undefined;
        var n: usize = 0;
        while (true) {
            if (rest.len == 0 or n == max_segments) return error.InvalidProjection;
            if (rest[0] == '(') {
                if (n == 0) return error.InvalidProjection;
                const close = std.mem.indexOfScalar(u8, rest, ')') orelse return error.InvalidProjection;
                if (close + 1 != rest.len) return error.InvalidProjection;
                var names = std.mem.splitScalar(u8, rest[1..close], ',');
                while (names.next()) |name| {
                    try validSegment(name);
                    segs[n] = name;
                    try self.appendPath(segs[0 .. n + 1], exclude);
                }
                return;
            }
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
            try validSegment(rest[0..dot]);
            segs[n] = rest[0..dot];
            n += 1;
            if (dot == rest.len) break;
            rest = rest[dot + 1 ..];
        }
        try self.appendPath(segs[0..n], exclude);
    }

    fn appendPath(self: *Projection, segments: []const []const u8, exclude: bool) Error!void {
        if (self.count == max_paths) return error.InvalidProjection;
        var path = Path{ .segments = undefined, .len = @intCast(segments.len), .exclude = exclude };
        for (segments, 0..) |seg, i| path.segments[i] = seg;
        self.paths[self.count] = path;
        self.count += 1;
        self.has_includes = self.has_includes or !exclude;
    }
};

/// Find the first comma that is not inside a group.
fn topLevelComma(s: []const u8) ?usize {
    var in_group = false;
    for (s, 0..) |c, i| {
        if (c == ',' and !in_group) return i;
        if (c == '(') in_group = true;
        if (c == ')') in_group = false;
    }
    return null;
}

fn validSegment(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_segment_bytes) return error.InvalidProjection;
    if (std.mem.eql(u8, name, "*")) return;
    for (name) |c| {
        if (c <= ' ' or c >= 0x7f) return error.InvalidProjection;
        switch (c) {
            '.', ',', '(', ')', '*', '!', '&', '=', '%', '+' => return error.InvalidProjection,
            else => {},
        }
    }
}

fn segMatch(seg: []const u8, child: Child) bool {
    if (std.mem.eql(u8, seg, "*")) return true;
    return switch (child) {
        .key => |key| std.mem.eql(u8, seg, key),
        .index => |index| indexMatch(seg, index),
    };
}

fn indexMatch(seg: []const u8, index: usize) bool {
    const parsed = std.fmt.parseInt(usize, seg, 10) catch return false;
    return parsed == index;
}

////////////////////////////////////////////////////////////////////////////////

fn expectPath(p: *const Projection, i: usize, want: []const []const u8, exclude: bool) !void {
    try std.testing.expectEqual(exclude, p.paths[i].exclude);
    try std.testing.expectEqual(want.len, p.paths[i].len);
    for (want, 0..) |seg, d|
        try std.testing.expectEqualStrings(seg, p.paths[i].segments[d]);
}

test "parse plain and grouped paths" {
    const p = try Projection.parse("country.names.en,location.(latitude,longitude)");
    try std.testing.expectEqual(@as(usize, 3), p.count);
    try std.testing.expect(p.has_includes);
    try expectPath(&p, 0, &.{ "country", "names", "en" }, false);
    try expectPath(&p, 1, &.{ "location", "latitude" }, false);
    try expectPath(&p, 2, &.{ "location", "longitude" }, false);
}

test "parse exclusions and wildcards" {
    const p = try Projection.parse("!location.accuracy_radius,*.names.en");
    try std.testing.expectEqual(@as(usize, 2), p.count);
    try expectPath(&p, 0, &.{ "location", "accuracy_radius" }, true);
    try expectPath(&p, 1, &.{ "*", "names", "en" }, false);

    const q = try Projection.parse("!continent,!country");
    try std.testing.expect(!q.has_includes);
    try expectPath(&q, 0, &.{"continent"}, true);
    try expectPath(&q, 1, &.{"country"}, true);
}

test "parse rejects malformed specs" {
    const bad = [_][]const u8{
        "",       ",",     "a,",     "a..b",   ".a",     "a.",    "!",   "!!a",  "a!",                "a)",
        "a.(b)c", "(a,b)", "a.(b,c", "a.(,b)", "a.(*,x", "%61.b", "a b", "a\nb", "a.b.c.d.e.f.g.h.i",
    };
    for (bad) |spec| {
        try std.testing.expectError(error.InvalidProjection, Projection.parse(spec));
    }
}

test "parse enforces the path limit" {
    var buf: [66]u8 = undefined;
    for (0..33) |i| {
        buf[2 * i] = 'a' + @as(u8, @intCast(i % 26));
        buf[2 * i + 1] = ',';
    }
    try std.testing.expectError(error.InvalidProjection, Projection.parse(buf[0 .. 33 * 2 - 1]));
}

test "parseQuery picks the f parameter" {
    const p = try Projection.parseQuery("x=1&f=a.b&y=2");
    try std.testing.expectEqual(@as(usize, 1), p.?.count);

    try std.testing.expectEqual(null, try Projection.parseQuery("x=1"));
    try std.testing.expectEqual(null, try Projection.parseQuery(""));
    try std.testing.expectEqual(null, try Projection.parseQuery("f"));
    try std.testing.expectError(error.InvalidProjection, Projection.parseQuery("f="));
    try std.testing.expectError(error.InvalidProjection, Projection.parseQuery("f=a,"));

    const last = try Projection.parseQuery("f=a&f=!b");
    try std.testing.expectEqual(@as(usize, 1), last.?.count);
    try std.testing.expect(!last.?.has_includes);
}

test "match children of maps and arrays" {
    const p = try Projection.parse("a.b,!a.c");
    var active: [max_paths]usize = undefined;
    for (0..p.count) |i| active[i] = i;
    var out: [max_paths]usize = undefined;

    const a = p.match(active[0..p.count], 0, .{ .key = "a" }, &out);
    try std.testing.expectEqual(@as(usize, 2), a.paths.len);
    try std.testing.expect(a.deep);
    try std.testing.expect(!a.inc_term);
    try std.testing.expect(!a.suppress);

    const b = p.match(a.paths, 1, .{ .key = "b" }, &out);
    try std.testing.expect(b.inc_term);
    try std.testing.expect(!b.suppress);

    const c = p.match(a.paths, 1, .{ .key = "c" }, &out);
    try std.testing.expect(c.suppress);

    const q = try Projection.parse("a.1,*.*");
    for (0..q.count) |i| active[i] = i;
    const e1 = q.match(active[0..q.count], 1, .{ .index = 1 }, &out);
    try std.testing.expectEqual(@as(usize, 2), e1.paths.len);
    const e2 = q.match(active[0..q.count], 1, .{ .index = 2 }, &out);
    try std.testing.expectEqual(@as(usize, 1), e2.paths.len);
    const e9 = q.match(active[0..q.count], 1, .{ .key = "x" }, &out);
    try std.testing.expectEqual(@as(usize, 1), e9.paths.len);
}
