const std = @import("std");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleWhois(_: *Display, msg: Message) !void {
    // params[1] is the queried nick for all these numerics.
    const nick = msg.params[1];
    var nb: [256]u8 = undefined;
    const styled_nick = fmt.paintNick(nick, &nb);
    if (std.mem.eql(u8, msg.command, "311")) {
        // [me, nick, user, host] + realname
        util.line("• {s} is {s}@{s} ({s})\n", .{ styled_nick, msg.params[2], msg.params[3], msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "312")) {
        // [me, nick, server] + server info
        util.line("• {s} on {s} ({s})\n", .{ styled_nick, msg.params[2], msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "313")) {
        util.line("• {s} {s}\n", .{ styled_nick, msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "317")) {
        // [me, nick, idle-secs] + signon info in trailing
        util.line("• {s} idle {s}s {s}\n", .{ styled_nick, msg.params[2], msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "319")) {
        util.line("• {s} on {s}\n", .{ styled_nick, msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "301")) {
        util.line("• {s} is away: {s}\n", .{ styled_nick, msg.trailing });
    } else if (std.mem.eql(u8, msg.command, "318")) {
        util.line("End of /whois for {s}\n", .{styled_nick});
    }
}

pub fn handleWhoLine(_: *Display, msg: Message) !void {
    // 352 params: [me, channel, user, host, server, nick, flags] + hopcount realname
    const nick = msg.params[5];
    if (nick.len == 0) return;
    var nb: [256]u8 = undefined;
    const flags = msg.params[6];
    const away = std.mem.indexOfScalar(u8, flags, 'G') != null;
    if (msg.trailing.len > 0) {
        util.line("• {s} {s}@{s} [{s}]{s}\n", .{
            fmt.paintNick(nick, &nb),
            msg.params[2],
            msg.params[3],
            flags,
            if (away) " (away)" else "",
        });
    } else {
        util.line("• {s} [{s}]{s}\n", .{ fmt.paintNick(nick, &nb), flags, if (away) " (away)" else "" });
    }
}

pub fn handleEndOfWho(_: *Display, msg: Message) !void {
    // 315 params: [me, target]
    if (msg.params[1].len == 0) return;
    util.line("End of /who for {s}\n", .{msg.params[1]});
}

pub fn handleChannelMode(_: *Display, msg: Message) !void {
    // 324 params: [me, channel, modes, ...args]
    const channel = msg.params[1];
    const modes = msg.params[2];
    if (channel.len == 0) return;
    var chb: [256]u8 = undefined;
    var argb: [256]u8 = undefined;
    const args = util.joinParams(msg.params[3..], &argb);
    if (modes.len > 0 and args.len > 0) {
        util.line("Modes for {s}: {s} {s}\n", .{ fmt.paintChannel(channel, &chb), modes, args });
    } else if (modes.len > 0) {
        util.line("Modes for {s}: {s}\n", .{ fmt.paintChannel(channel, &chb), modes });
    } else {
        util.line("No modes set on {s}\n", .{fmt.paintChannel(channel, &chb)});
    }
}

pub fn handleChannelCreated(_: *Display, msg: Message) !void {
    // 329 params: [me, channel, timestamp]
    if (msg.params[1].len == 0) return;
    var chb: [256]u8 = undefined;
    if (msg.params[2].len > 0) {
        util.line("{s} created at {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), msg.params[2] });
    }
}

pub fn handleInviteConfirm(_: *Display, msg: Message) !void {
    // 341 params: [me, nick, channel]
    const nick = msg.params[1];
    const channel = msg.params[2];
    if (nick.len == 0) return;
    var nb: [256]u8 = undefined;
    if (channel.len > 0) {
        var chb: [256]u8 = undefined;
        util.line("{s} invited to {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
    } else {
        util.line("{s} invited\n", .{fmt.paintNick(nick, &nb)});
    }
}

/// Show server rejections for messages we tried to send, e.g.
/// 404 "Cannot send to channel" when not joined. params[1] is the
/// target, trailing carries the human-readable reason.
pub fn handleSendError(_: *Display, msg: Message) !void {
    const target = msg.params[1];
    if (target.len > 0 and msg.trailing.len > 0) {
        util.errLine("{s}: {s}\n", .{ target, msg.trailing });
    } else if (msg.trailing.len > 0) {
        util.errLine("{s}\n", .{msg.trailing});
    } else if (target.len > 0) {
        util.errLine("{s}: command failed ({s})\n", .{ target, msg.command });
    }
}
