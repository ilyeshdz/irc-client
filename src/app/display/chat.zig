const std = @import("std");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const list = @import("list.zig");
const util = @import("util.zig");

pub fn handlePrivmsg(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const nick = util.nickOnly(prefix);
    const target = msg.params[0];
    if (target.len == 0) return;

    // History key: the channel, or the peer's nick for PMs (one entry
    // per counterpart).
    var conv = target;
    if (!util.isChannelTarget(target)) {
        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, target, my_nick)) {
                conv = nick;
                // PMs have no join event: replay before the first message seen.
                self.ensureReplayed(nick);
            }
        }
    }
    self.record(conv, nick, msg.trailing);

    if (util.parseAction(msg.trailing)) |action| {
        var nb: [256]u8 = undefined;
        if (util.isChannelTarget(target)) {
            var chb: [256]u8 = undefined;
            if (mentionsNick(action, self.current_nick, nick)) {
                if (fmt.isEnabled()) {
                    const hl = fmt.bold ++ fmt.yellow;
                    util.line("{s} * {s} >> {s}{s}{s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), hl, action, fmt.reset });
                } else {
                    util.line("{s} * {s} >> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), action });
                }
            } else {
                util.line("{s} * {s} {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), action });
            }
        } else {
            util.line("* {s} {s}\n", .{ fmt.paintNick(nick, &nb), action });
        }
        return;
    }

    var nb: [256]u8 = undefined;
    if (util.isChannelTarget(target)) {
        var chb: [256]u8 = undefined;
        const mentioned = mentionsNick(msg.trailing, self.current_nick, nick);
        if (mentioned) {
            // A mention must stand out with colors on and stay readable
            // with them off (plain `>>` marker, no escapes).
            if (fmt.isEnabled()) {
                const hl = fmt.bold ++ fmt.yellow;
                util.line("{s} <{s}> >> {s}{s}{s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), hl, msg.trailing, fmt.reset });
            } else {
                util.line("{s} <{s}> >> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), msg.trailing });
            }
        } else {
            util.line("{s} <{s}> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), msg.trailing });
        }
    } else if (self.current_nick) |my_nick| {
        if (std.mem.eql(u8, target, my_nick)) {
            util.line("PM from {s}: {s}\n", .{ fmt.paintNick(nick, &nb), msg.trailing });
        } else {
            util.line("PM to {s}: {s}\n", .{ target, msg.trailing });
        }
    }
}

pub fn handleNotice(self: *Display, msg: Message) !void {
    const target = msg.params[0];
    if (target.len == 0) return;
    list.noteListRefusal(self, msg.trailing);
    if (self.current_nick) |my_nick| {
        if (!std.mem.eql(u8, target, my_nick) and !util.isChannelTarget(target)) return;
    }
    if (msg.prefix) |prefix| {
        const nick = util.nickOnly(prefix);
        var nb: [256]u8 = undefined;
        if (util.isChannelTarget(target)) {
            var chb: [256]u8 = undefined;
            util.line("{s} -{s}- {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), msg.trailing });
        } else {
            util.line("-{s}- {s}\n", .{ fmt.paintNick(nick, &nb), msg.trailing });
        }
    } else {
        util.line("-server- {s}\n", .{msg.trailing});
    }
}

/// True when a channel message calls out our nick: case-insensitive
/// substring match. Own messages and PMs never count (callers only pass
/// channel text from other users).
pub fn mentionsNick(text: []const u8, my_nick: ?[]const u8, sender: []const u8) bool {
    const me = my_nick orelse return false;
    if (me.len == 0 or text.len < me.len) return false;
    if (std.ascii.eqlIgnoreCase(sender, me)) return false;
    var i: usize = 0;
    while (i + me.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + me.len], me)) return true;
    }
    return false;
}

test "mentions match our nick case-insensitively, never ourselves" {
    const t = std.testing;
    try t.expect(mentionsNick("hey Tester, look", "tester", "alice"));
    try t.expect(mentionsNick("TESTER!", "tester", "alice"));
    try t.expect(!mentionsNick("hey alice, look", "tester", "alice"));
    try t.expect(!mentionsNick("hey tester", "tester", "tester"));
    try t.expect(!mentionsNick("hey tester", "tester", "TESTER"));
    try t.expect(!mentionsNick("hi", null, "alice"));
    try t.expect(!mentionsNick("", "tester", "alice"));
    try t.expect(!mentionsNick("tes", "tester", "alice"));
}
