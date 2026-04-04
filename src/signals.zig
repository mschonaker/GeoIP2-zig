const std = @import("std");

var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn initSignals() void {
    {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = &handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    }
    {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = &handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    }
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .unordered);
}

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.unordered);
}
