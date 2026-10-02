const std = @import("std");

// TODO: Implement the with_short property so that he verify both short and long version of the flag
pub fn getValueForOption(args: []const []const u8, option: []const u8, with_short: bool) ?[]const u8 {
    std.debug.print("with short = {s}\n", .{if (with_short) "true" else "false"});
    var value: ?[]const u8 = null;
    for (args, 0..) |arg, index| {
        if (arg.len == option.len + 2 and std.mem.startsWith(u8, arg, "--")) {
            if (index + 1 < args.len) {
                value = args[index + 1];
                break;
            }
        }
    }
    return value;
}
