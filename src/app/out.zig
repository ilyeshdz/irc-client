const std = @import("std");
const builtin = @import("builtin");

/// Every line the app writes to the terminal goes through here, so there is
/// exactly one place that decides whether output happens at all.
///
/// Tests must stay silent: the build runner captures a test binary's stderr
/// and prints it back with a `failed command:` line even when every test
/// passes, which makes a green `zig build test` look like a red one.
pub fn print(comptime f: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(f, args);
}
