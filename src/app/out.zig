const std = @import("std");
const builtin = @import("builtin");

/// Single choke point for terminal output. Silent under test: the build
/// runner reprints a test binary's stderr as failure output even on success.
pub fn print(comptime f: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(f, args);
}
