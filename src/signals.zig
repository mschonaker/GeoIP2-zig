const std = @import("std");
const zio = @import("zio");

/// Suspend the calling fiber until SIGINT or SIGTERM arrives.
pub fn waitForSignal() void {
    var sigint = zio.Signal.init(.interrupt) catch return;
    defer sigint.deinit();

    var sigterm = zio.Signal.init(.terminate) catch return;
    defer sigterm.deinit();

    _ = zio.select(.{ .sigint = &sigint, .sigterm = &sigterm }) catch {};
}
