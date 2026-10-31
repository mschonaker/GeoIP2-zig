// GeoIP2-zig
// Fuzz target for the MMDB binary parser.
// Run with: zig build fuzz --fuzz[=limit]

const std = @import("std");
const mmdb = @import("mmdb.zig");
const Smith = std.testing.Smith;

const max_input_bytes = 1 << 20;
const max_output_bytes = 1 << 18;
const min_mmdb_bytes = 128 * 1024;

const corpus_files = [_][]const u8{
    @embedFile("corpus/real.mmdb"),
    @embedFile("corpus/trie24.mmdb"),
    @embedFile("corpus/trie28.mmdb"),
    @embedFile("corpus/trie32.mmdb"),
    @embedFile("corpus/types.mmdb"),
    @embedFile("corpus/deep.mmdb"),
    @embedFile("corpus/strings.mmdb"),
    @embedFile("corpus/metadata_minimal.mmdb"),
    @embedFile("corpus/metadata_full.mmdb"),
    @embedFile("corpus/metadata_edge.mmdb"),
};

const corpus_total = blk: {
    var total: usize = 0;
    for (corpus_files) |file| total += 4 + file.len + 1 + 16 + 8;
    break :blk total;
};

test "fuzz mmdb parser" {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, corpus_total);
    defer allocator.free(buf);
    const inputs = try allocator.alloc([]const u8, corpus_files.len);
    defer allocator.free(inputs);

    var pos: usize = 0;
    for (corpus_files, 0..) |file, i| {
        const start = pos;
        std.mem.writeInt(u32, @ptrCast(&buf[pos]), @intCast(file.len), .little);
        pos += 4;
        @memcpy(buf[pos..][0..file.len], file);
        pos += file.len;
        buf[pos] = 0;
        pos += 1;
        @memset(buf[pos..][0..16], 0);
        buf[pos] = @intCast((i % 16) << 4);
        pos += 16;
        std.mem.writeInt(u64, @ptrCast(&buf[pos]), 1000, .little);
        pos += 8;
        inputs[i] = buf[start..pos];
    }
    std.debug.assert(pos == corpus_total);

    try std.testing.fuzz({}, fuzzMmdb, .{ .corpus = inputs });
}

test "corpus seeds initialize" {
    for (corpus_files, 0..) |seed, i| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();

        var file = mmdb.MMDBFile.init(seed, arena_state.allocator(), true) catch |err| {
            std.debug.print("corpus seed {d} failed: {}\n", .{ i, err });
            return err;
        };
        defer file.deinit();
    }
}

fn fuzzMmdb(_: void, smith: *Smith) !void {
    var buf: [max_input_bytes]u8 = undefined;
    const len = smith.sliceWeighted(
        &buf,
        &.{
            .rangeAtMost(u32, min_mmdb_bytes, max_input_bytes, 3),
            .rangeAtMost(u32, 0, min_mmdb_bytes, 1),
        },
        &.{.rangeAtMost(u8, 0, 255, 1)},
    );
    const data = buf[0..len];
    if (smith.eos()) return;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();

    var file = mmdb.MMDBFile.init(data, arena_state.allocator(), true) catch return;
    defer file.deinit();

    var address: [16]u8 = undefined;
    smith.bytes(&address);

    var out: [max_output_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    file.lookupIpV6(address, &w) catch {};
    w.end = 0;

    const offset = smith.index(data.len);
    _ = file.writeData(offset, &w) catch 0;
}
