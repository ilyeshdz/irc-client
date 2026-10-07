const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleAwayOff(_: *Display, _: Message) !void {
    util.line("You are no longer marked as away\n", .{});
}

pub fn handleAwayOn(_: *Display, _: Message) !void {
    util.line("You are now marked as away\n", .{});
}

pub fn handleWelcome(_: *Display, msg: Message) !void {
    util.statusLine(
        "{s}✓ connected{s} {s}\n",
        .{ fmt.green, fmt.reset, msg.trailing },
        "Connected: {s}\n",
        .{msg.trailing},
    );
}

pub fn handleHost(_: *Display, msg: Message) !void {
    util.line("Host: {s}\n", .{msg.trailing});
}

pub fn handleCreated(_: *Display, msg: Message) !void {
    util.line("Created: {s}\n", .{msg.trailing});
}

pub fn handleServerInfo(_: *Display, msg: Message) !void {
    if (msg.params[0].len > 0) util.line("Server: {s}\n", .{msg.params[0]});
}

pub fn handleNickInUse(_: *Display, msg: Message) !void {
    if (msg.params[1].len > 0) {
        var nb: [256]u8 = undefined;
        util.errLine("Nickname {s} is already in use\n", .{fmt.paintNick(msg.params[1], &nb)});
    }
}

pub fn handleNeedMoreParams(_: *Display, msg: Message) !void {
    if (msg.params[1].len > 0) util.errLine("{s}: not enough parameters\n", .{msg.params[1]});
}

pub fn handleUnknownCommand(_: *Display, msg: Message) !void {
    if (msg.params[1].len > 0) {
        util.errLine("{s}: {s}\n", .{ msg.params[1], msg.trailing });
    } else if (msg.trailing.len > 0) {
        util.errLine("{s}\n", .{msg.trailing});
    }
}
