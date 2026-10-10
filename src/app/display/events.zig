const std = @import("std");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleJoin(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const nick = util.nickOnly(prefix);
    const channel = msg.params[0];
    if (channel.len == 0) return;

    if (self.current_nick) |my_nick| {
        const is_self = std.mem.eql(u8, nick, my_nick);
        self.noteJoin(channel, nick, is_self);
        if (is_self) {
            var chb: [256]u8 = undefined;
            util.event("You joined {s}\n", .{fmt.paintChannel(channel, &chb)});
            self.setCurrentChannel(channel) catch |err| std.log.warn("could not track joined channel {s}: {s}", .{ channel, @errorName(err) });
            util.line("now talking in {s} — type a message, /help for commands\n", .{fmt.paintChannel(channel, &chb)});
            self.ensureReplayed(channel);
        } else {
            var nb: [256]u8 = undefined;
            var chb: [256]u8 = undefined;
            util.event("{s} joined {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
        }
    }
}

pub fn handlePart(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const nick = util.nickOnly(prefix);
    const channel = msg.params[0];
    if (channel.len == 0) return;

    if (self.current_nick) |my_nick| {
        const is_self = std.mem.eql(u8, nick, my_nick);
        self.notePart(channel, nick, is_self);
        if (is_self) {
            var chb: [256]u8 = undefined;
            util.event("You left {s}\n", .{fmt.paintChannel(channel, &chb)});
            if (self.current_channel) |current| {
                if (std.mem.eql(u8, current, channel)) self.setCurrentChannel(null) catch |err| std.log.warn("could not clear current channel {s}: {s}", .{ channel, @errorName(err) });
            }
        } else if (util.reasonOf(msg, 1).len > 0) {
            var nb: [256]u8 = undefined;
            var chb: [256]u8 = undefined;
            util.event("{s} left {s} ({s})\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb), util.reasonOf(msg, 1) });
        } else {
            var nb: [256]u8 = undefined;
            var chb: [256]u8 = undefined;
            util.event("{s} left {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
        }
    }
}

pub fn handleQuit(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const nick = util.nickOnly(prefix);
    self.noteQuit(nick);
    var nb: [256]u8 = undefined;
    if (util.reasonOf(msg, 0).len > 0) {
        util.event("{s} quit ({s})\n", .{ fmt.paintNick(nick, &nb), util.reasonOf(msg, 0) });
    } else {
        util.event("{s} quit\n", .{fmt.paintNick(nick, &nb)});
    }
}

pub fn handleKick(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const kicker = util.nickOnly(prefix);
    const channel = msg.params[0];
    const target = msg.params[1];
    if (channel.len == 0 or target.len == 0) return;
    var kb: [256]u8 = undefined;
    var tb: [256]u8 = undefined;
    var chb: [256]u8 = undefined;
    if (util.reasonOf(msg, 2).len > 0) {
        util.event("{s} kicked {s} from {s} ({s})\n", .{
            fmt.paintNick(kicker, &kb),
            fmt.paintNick(target, &tb),
            fmt.paintChannel(channel, &chb),
            util.reasonOf(msg, 2),
        });
    } else {
        util.event("{s} kicked {s} from {s}\n", .{
            fmt.paintNick(kicker, &kb),
            fmt.paintNick(target, &tb),
            fmt.paintChannel(channel, &chb),
        });
    }
    if (self.current_nick) |my_nick| {
        self.noteKick(channel, target, std.mem.eql(u8, target, my_nick));
        if (std.mem.eql(u8, target, my_nick)) {
            if (self.current_channel) |current| {
                if (std.mem.eql(u8, current, channel)) self.setCurrentChannel(null) catch |err| std.log.warn("could not clear current channel {s}: {s}", .{ channel, @errorName(err) });
            }
        }
    }
}

pub fn handleMode(_: *Display, msg: Message) !void {
    const target = msg.params[0];
    const modes = msg.params[1];
    if (target.len == 0 or modes.len == 0) return;
    var argb: [256]u8 = undefined;
    const args = util.joinParams(msg.params[2..], &argb);
    if (msg.prefix) |prefix| {
        const nick = util.nickOnly(prefix);
        var nb: [256]u8 = undefined;
        if (args.len > 0) {
            util.event("{s} set mode {s} {s} on {s}\n", .{ fmt.paintNick(nick, &nb), modes, args, target });
        } else {
            util.event("{s} set mode {s} on {s}\n", .{ fmt.paintNick(nick, &nb), modes, target });
        }
    } else if (args.len > 0) {
        util.line("Mode {s} {s} on {s}\n", .{ modes, args, target });
    } else {
        util.line("Mode {s} on {s}\n", .{ modes, target });
    }
}

pub fn handleInvite(_: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const nick = util.nickOnly(prefix);
    // INVITE layouts vary: [me, channel] usually, target first on some.
    const channel = if (msg.params[1].len > 0) msg.params[1] else msg.trailing;
    if (channel.len == 0) return;
    var nb: [256]u8 = undefined;
    var chb: [256]u8 = undefined;
    util.event("{s} invited you to {s} — /join {s} to accept\n", .{
        fmt.paintNick(nick, &nb),
        fmt.paintChannel(channel, &chb),
        channel,
    });
}

pub fn handleNick(self: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const old_nick = util.nickOnly(prefix);
    const new_nick = msg.params[0];
    if (new_nick.len == 0) return;

    if (self.current_nick) |my_nick| {
        if (std.mem.eql(u8, old_nick, my_nick)) {
            var nb: [256]u8 = undefined;
            util.event("You are now known as {s}\n", .{fmt.paintNick(new_nick, &nb)});
            self.noteNick(old_nick, new_nick);
            self.setCurrentNick(new_nick) catch |err| std.log.warn("could not track nick change to {s}: {s}", .{ new_nick, @errorName(err) });
        } else {
            var ob: [256]u8 = undefined;
            var nb: [256]u8 = undefined;
            util.event("{s} is now known as {s}\n", .{ fmt.paintNick(old_nick, &ob), fmt.paintNick(new_nick, &nb) });
            self.noteNick(old_nick, new_nick);
        }
    }
}

test "being kicked clears the current channel" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    try d.setCurrentChannel("#zig");
    try handleKick(&d, .{
        .prefix = "op!u@h",
        .command = "KICK",
        .params = .{ "#zig", "tester" } ++ .{""} ** 13,
        .trailing = "bye",
    });
    try t.expect(d.current_channel == null);
}
