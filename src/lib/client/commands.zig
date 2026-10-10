const std = @import("std");
const Message = @import("../message.zig").Message;
const IrcClient = @import("mod.zig").IrcClient;
const send = @import("send.zig");
const state = @import("state.zig");

/// Join a channel (remembered for reconnects).
pub fn joinChannel(self: *IrcClient, channel: []const u8) !void {
    try state.rememberChannel(self, channel);
    try send.send(self, Message{ .command = "JOIN", .params = .{channel} ++ .{""} ** 14 });
}

pub fn listChannels(self: *IrcClient) !void {
    try send.sendRaw(self, "LIST", "");
}

pub fn changeNick(self: *IrcClient, nick: []const u8) !void {
    try send.send(self, Message{ .command = "NICK", .params = .{nick} ++ .{""} ** 14 });
}

/// 433 fallback: our nick is taken. Appends "_" and retries once; the
/// caller repeats on the next 433. Returns the new nick owned by the client.
pub fn useAlternateNick(self: *IrcClient) ![]const u8 {
    const base = if (self.current_nick.len > 0) self.current_nick else self.username;
    if (base.len == 0) return error.InvalidMessage;
    var buf: [33]u8 = undefined;
    const alt = alternateFor(base, &buf);
    try send.send(self, Message{ .command = "NICK", .params = .{alt} ++ .{""} ** 14 });
    try self.replaceOwned(&self.current_nick, alt);
    return self.current_nick;
}

/// Pure nick fallback used by useAlternateNick: `bob` -> `bob_`,
/// truncated to 32 so the retry survives server nicklen limits.
pub fn alternateFor(base: []const u8, buf: *[33]u8) []const u8 {
    const max_nick: usize = 32;
    if (base.len + 1 <= max_nick) {
        @memcpy(buf[0..base.len], base);
        buf[base.len] = '_';
        return buf[0 .. base.len + 1];
    }
    @memcpy(buf[0 .. max_nick - 1], base[0 .. max_nick - 1]);
    buf[max_nick - 1] = '_';
    return buf[0..max_nick];
}

pub fn requestTopic(self: *IrcClient, channel: []const u8) !void {
    try send.send(self, Message{ .command = "TOPIC", .params = .{channel} ++ .{""} ** 14 });
}

pub fn setTopic(self: *IrcClient, channel: []const u8, text: []const u8) !void {
    try send.send(self, Message{ .command = "TOPIC", .params = .{channel} ++ .{""} ** 14, .trailing = text });
}

/// Request the user list of a channel (or all visible users if null).
pub fn requestNames(self: *IrcClient, channel: ?[]const u8) !void {
    if (channel) |ch| {
        try send.send(self, Message{ .command = "NAMES", .params = .{ch} ++ .{""} ** 14 });
    } else {
        try send.send(self, Message{ .command = "NAMES" });
    }
}

pub fn whois(self: *IrcClient, nick: []const u8) !void {
    try send.send(self, Message{ .command = "WHOIS", .params = .{nick} ++ .{""} ** 14 });
}

pub fn who(self: *IrcClient, target: []const u8) !void {
    try send.send(self, Message{ .command = "WHO", .params = .{target} ++ .{""} ** 14 });
}

pub fn requestMode(self: *IrcClient, target: []const u8) !void {
    try send.send(self, Message{ .command = "MODE", .params = .{target} ++ .{""} ** 14 });
}

/// Set modes on a target, e.g. `/mode #zig +o alice`.
pub fn setMode(self: *IrcClient, target: []const u8, modes: []const u8) !void {
    // One param per token: the server would re-split a param with spaces.
    var params: [15][]const u8 = .{""} ** 15;
    params[0] = target;
    var n: usize = 1;
    var it = std.mem.tokenizeScalar(u8, modes, ' ');
    while (it.next()) |tok| {
        if (n >= params.len) break;
        params[n] = tok;
        n += 1;
    }
    if (n == 1) return error.InvalidMessage;
    try send.send(self, Message{ .command = "MODE", .params = params });
}

pub fn kick(self: *IrcClient, channel: []const u8, nick: []const u8, reason: ?[]const u8) !void {
    if (reason) |r| {
        try send.send(self, Message{ .command = "KICK", .params = .{ channel, nick } ++ .{""} ** 13, .trailing = r });
    } else {
        try send.send(self, Message{ .command = "KICK", .params = .{ channel, nick } ++ .{""} ** 13 });
    }
}

pub fn invite(self: *IrcClient, nick: []const u8, channel: []const u8) !void {
    try send.send(self, Message{ .command = "INVITE", .params = .{ nick, channel } ++ .{""} ** 13 });
}

/// Set yourself away (no message clears the away status).
pub fn away(self: *IrcClient, message: ?[]const u8) !void {
    if (message) |m| {
        try send.send(self, Message{ .command = "AWAY", .trailing = m });
    } else {
        try send.send(self, Message{ .command = "AWAY" });
    }
}

/// Send a /me action (CTCP ACTION) to a target.
pub fn sendAction(self: *IrcClient, target: []const u8, text: []const u8) !void {
    var buf: [512]u8 = undefined;
    const action = std.fmt.bufPrint(&buf, "\x01ACTION {s}\x01", .{text}) catch return error.MessageTooLong;
    try send.send(self, Message{ .command = "PRIVMSG", .params = .{target} ++ .{""} ** 14, .trailing = action });
}

pub fn sendMessage(self: *IrcClient, target: []const u8, text: []const u8) !void {
    try send.send(self, Message{ .command = "PRIVMSG", .params = .{target} ++ .{""} ** 14, .trailing = text });
}

pub fn sendNotice(self: *IrcClient, target: []const u8, text: []const u8) !void {
    try send.send(self, Message{ .command = "NOTICE", .params = .{target} ++ .{""} ** 14, .trailing = text });
}

pub fn partChannel(self: *IrcClient, channel: []const u8, reason: ?[]const u8) !void {
    state.forgetChannel(self, channel);
    if (reason) |r| {
        try send.send(self, Message{ .command = "PART", .params = .{channel} ++ .{""} ** 14, .trailing = r });
    } else {
        try send.send(self, Message{ .command = "PART", .params = .{channel} ++ .{""} ** 14 });
    }
}

pub fn quit(self: *IrcClient, reason: ?[]const u8) !void {
    if (reason) |r| {
        try send.send(self, Message{ .command = "QUIT", .trailing = r });
    } else {
        try send.send(self, Message{ .command = "QUIT" });
    }
}

test "433 fallback appends underscore within nicklen" {
    var buf: [33]u8 = undefined;
    try std.testing.expectEqualStrings("bob_", alternateFor("bob", &buf));
    var long: [32]u8 = undefined;
    @memset(&long, 'a');
    const alt = alternateFor(&long, &buf);
    try std.testing.expectEqual(@as(usize, 32), alt.len);
    try std.testing.expect(alt[31] == '_');
}
