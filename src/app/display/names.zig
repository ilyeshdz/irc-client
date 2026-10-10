const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleNames(self: *Display, msg: Message) !void {
    // params: [nick, =, channel]
    if (msg.params[2].len == 0) return;
    self.noteNames(msg.params[2], msg.trailing);
    var chb: [256]u8 = undefined;
    util.line("Users in {s}: {s}\n", .{ fmt.paintChannel(msg.params[2], &chb), msg.trailing });
}

pub fn handleEndOfNames(_: *Display, msg: Message) !void {
    if (msg.params[1].len == 0) return;
    var chb: [256]u8 = undefined;
    util.line("End of /names for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
}
