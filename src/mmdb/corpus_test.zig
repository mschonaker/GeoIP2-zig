// GeoIP2-zig
// Regression tests for the generated fuzz corpus.

const std = @import("std");
const mmdb = @import("mmdb.zig");

const trie_seeds = [_][]const u8{
    @embedFile("corpus/trie24.mmdb"),
    @embedFile("corpus/trie28.mmdb"),
    @embedFile("corpus/trie32.mmdb"),
};

const leaf_offsets = [16]?usize{
    0, 8, 16, 24, 32, 40, 56, 64, 96, 128, 160, 176, 192, 100_000, 65_536, null,
};

fn addressForLeaf(leaf: usize) [16]u8 {
    var address: [16]u8 = @splat(0);
    address[0] = @intCast(leaf << 4);
    return address;
}

test "multi-node tries resolve every leaf" {
    for (trie_seeds) |seed| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();

        var file = try mmdb.MMDBFile.init(seed, arena_state.allocator(), true);
        defer file.deinit();

        for (leaf_offsets, 0..) |expected, leaf| {
            const address = addressForLeaf(leaf);
            const found = file.locateDataNode(address);

            if (expected) |offset| {
                try std.testing.expectEqual(
                    file.nodes_offset + offset,
                    found orelse return error.TestUnexpectedResult,
                );

                var out: [4096]u8 = undefined;
                var w: std.Io.Writer = .fixed(&out);
                try file.lookupIpV6(address, &w);
            } else {
                try std.testing.expect(found == null);

                var out: [4096]u8 = undefined;
                var w: std.Io.Writer = .fixed(&out);
                try std.testing.expectError(error.NoData, file.lookupIpV6(address, &w));
            }
        }

        var out: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try file.lookupIpV6(addressForLeaf(0), &w);
        try std.testing.expectEqualStrings("\"leaf0\"", out[0..w.end]);
    }
}

test "type coverage seed reaches every decoder branch" {
    const seed = @embedFile("corpus/types.mmdb");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var file = try mmdb.MMDBFile.init(seed, arena_state.allocator(), true);
    defer file.deinit();

    const Outcome = enum { ok, invalid, no_data };
    const outcomes = [16]Outcome{
        .ok,      .ok,      .ok,      .ok,
        .ok,      .ok,      .ok,      .ok,
        .invalid, .invalid, .invalid, .ok,
        .ok,      .invalid, .invalid, .no_data,
    };

    for (outcomes, 0..) |outcome, leaf| {
        const address = addressForLeaf(leaf);
        var out: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);

        switch (outcome) {
            .ok => try file.lookupIpV6(address, &w),
            .invalid => try std.testing.expectError(error.InvalidFormat, file.lookupIpV6(address, &w)),
            .no_data => try std.testing.expectError(error.NoData, file.lookupIpV6(address, &w)),
        }
    }
}

test "deep nesting and long strings serialize" {
    const seeds = [_][]const u8{
        @embedFile("corpus/deep.mmdb"),
        @embedFile("corpus/strings.mmdb"),
    };

    for (seeds) |seed| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();

        var file = try mmdb.MMDBFile.init(seed, arena_state.allocator(), true);
        defer file.deinit();

        var out: [1 << 17]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try file.lookupIpV6(addressForLeaf(0), &w);
    }
}

test "metadata seeds print" {
    const seeds = [_][]const u8{
        @embedFile("corpus/metadata_minimal.mmdb"),
        @embedFile("corpus/metadata_full.mmdb"),
        @embedFile("corpus/metadata_edge.mmdb"),
    };

    for (seeds) |seed| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();

        var file = try mmdb.MMDBFile.init(seed, arena_state.allocator(), true);
        defer file.deinit();

        var out: [1 << 16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try file.print(&w);
    }
}
