const std = @import("std");
const out = @import("../out.zig");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const hist = @import("../history.zig");
const History = hist.History;
const HistMessage = hist.Message;
const util = @import("util.zig");

const motd = @import("motd.zig");
const list = @import("list.zig");
const names = @import("names.zig");
const events = @import("events.zig");
const chat = @import("chat.zig");
const topic = @import("topic.zig");
const who = @import("who.zig");
const status = @import("status.zig");

/// Newest saved messages printed when a conversation is first shown.
const max_replay = 50;

pub const Display = struct {
    // State shared with the `display/` domain modules (motd, list,
    // events, ...), which implement handlers as free functions taking
    // `*Display`. Struct fields are always visible wherever the type is;
    // only methods need `pub` below.
    allocator: std.mem.Allocator,
    motd_buffer: std.ArrayList(u8),
    collecting_motd: bool,
    in_channel_list: bool,
    list_pending: bool,
    list_count: usize,
    list_refused: bool,
    current_channel: ?[]const u8,
    current_nick: ?[]const u8,
    history: ?*History,
    server_ip: ?[]const u8,
    history_warned: bool,
    replayed: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !Display {
        const motd_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        return Display{
            .allocator = allocator,
            .motd_buffer = motd_buffer,
            .collecting_motd = false,
            .in_channel_list = false,
            .list_pending = false,
            .list_count = 0,
            .list_refused = false,
            .current_channel = null,
            .current_nick = null,
            .history = null,
            .server_ip = null,
            .history_warned = false,
            .replayed = .empty,
        };
    }

    pub fn deinit(self: *Display) void {
        self.motd_buffer.deinit(self.allocator);
        if (self.current_channel) |c| self.allocator.free(c);
        if (self.current_nick) |n| self.allocator.free(n);
        if (self.server_ip) |s| self.allocator.free(s);
        for (self.replayed.items) |conv| self.allocator.free(conv);
        self.replayed.deinit(self.allocator);
    }

    pub fn setHistory(self: *Display, history: *History, server_ip: []const u8) !void {
        if (self.server_ip) |old| {
            self.allocator.free(old);
            self.server_ip = null;
        }
        self.history = history;
        self.server_ip = try self.allocator.dupe(u8, server_ip);
    }

    pub fn record(self: *Display, conv: []const u8, sender: []const u8, content: []const u8) void {
        const h = self.history orelse return;
        const ip = self.server_ip orelse return;
        h.addMessage(ip, conv, .{
            .sender = sender,
            .timestamp = fmt.nowSecs() orelse 0,
            .content = content,
        }) catch {
            if (!self.history_warned) {
                self.history_warned = true;
                util.errLine("could not save history to disk\n", .{});
            }
        };
    }

    /// Saved messages for `conv` on the current server, if any.
    fn savedFor(self: *Display, conv: []const u8) ?[]const HistMessage {
        const h = self.history orelse return null;
        const ip = self.server_ip orelse return null;
        for (h.servers.items) |*server| {
            if (!std.mem.eql(u8, server.ip, ip)) continue;
            for (server.channels.items) |*channel| {
                if (std.mem.eql(u8, channel.name, conv)) return channel.messages.items;
            }
        }
        return null;
    }

    /// The newest `max_replay` entries of a saved log.
    fn replayWindow(messages: []const HistMessage) []const HistMessage {
        if (messages.len <= max_replay) return messages;
        return messages[messages.len - max_replay ..];
    }

    /// Print saved history for a conversation exactly once per session,
    /// so a rejoin or a chatty PM doesn't repeat the scrollback.
    pub fn ensureReplayed(self: *Display, conv: []const u8) void {
        for (self.replayed.items) |seen| {
            if (std.mem.eql(u8, seen, conv)) return;
        }
        self.replay(conv);
        const duped = self.allocator.dupe(u8, conv) catch return;
        self.replayed.append(self.allocator, duped) catch {
            self.allocator.free(duped);
        };
    }

    fn replay(self: *Display, conv: []const u8) void {
        const msgs = self.savedFor(conv) orelse return;
        const win = replayWindow(msgs);
        if (win.len == 0) return;

        out.print("\n", .{});
        if (fmt.isEnabled()) {
            out.print("{s}--- history: {d} of {d} messages ---{s}\n", .{ fmt.dim, win.len, msgs.len, fmt.reset });
        } else {
            out.print("--- history: {d} of {d} messages ---\n", .{ win.len, msgs.len });
        }
        for (win) |m| self.printHistoryLine(conv, m);
    }

    /// One saved message, styled like its live counterpart but keeping the
    /// timestamp it was originally sent at.
    fn printHistoryLine(self: *Display, conv: []const u8, m: HistMessage) void {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        const ts = fmt.dimTimestampAt(m.timestamp, &tsb, &tss);
        var nb: [256]u8 = undefined;
        const styled_nick = fmt.paintNick(m.sender, &nb);
        const action = util.parseAction(m.content);
        const content = action orelse m.content;

        if (util.isChannelTarget(conv)) {
            var chb: [256]u8 = undefined;
            const styled_conv = fmt.paintChannel(conv, &chb);
            if (action != null) {
                out.print("{s} {s} * {s} {s}\n", .{ ts, styled_conv, styled_nick, content });
            } else {
                out.print("{s} {s} <{s}> {s}\n", .{ ts, styled_conv, styled_nick, content });
            }
            return;
        }

        const mine = if (self.current_nick) |me| std.mem.eql(u8, m.sender, me) else false;
        if (mine) {
            out.print("{s} PM to {s}: {s}\n", .{ ts, conv, content });
        } else if (action != null) {
            out.print("{s} * {s} {s}\n", .{ ts, styled_nick, content });
        } else {
            out.print("{s} PM from {s}: {s}\n", .{ ts, styled_nick, content });
        }
    }

    pub fn setCurrentChannel(self: *Display, channel: ?[]const u8) !void {
        if (self.current_channel) |c| {
            self.allocator.free(c);
            self.current_channel = null;
        }
        if (channel) |ch| {
            if (ch.len == 0) return;
            self.current_channel = try self.allocator.dupe(u8, ch);
        }
    }

    pub fn setCurrentNick(self: *Display, nick: []const u8) !void {
        if (self.current_nick) |n| {
            self.allocator.free(n);
            self.current_nick = null;
        }
        if (nick.len == 0) return;
        self.current_nick = try self.allocator.dupe(u8, nick);
    }

    /// Local status line (no server behind it).
    pub fn info(_: *Display, comptime f: []const u8, args: anytype) void {
        util.line(f, args);
    }

    /// Local error line (no server behind it).
    pub fn err(_: *Display, comptime f: []const u8, args: anytype) void {
        util.errLine(f, args);
    }

    /// The TCP connection is back; the server's 001 prints separately.
    pub fn reconnected(_: *Display) void {
        util.statusLine(
            "{s}✓ reconnected{s}\n",
            .{ fmt.green, fmt.reset },
            "Reconnected\n",
            .{},
        );
    }

    /// Drop MOTD/LIST state owned by the connection that just died.
    pub fn resetConnectionState(self: *Display) void {
        self.collecting_motd = false;
        self.motd_buffer.clearRetainingCapacity();
        self.in_channel_list = false;
        self.list_pending = false;
        self.list_count = 0;
        self.list_refused = false;
    }

    /// Called when the user requests a channel list, so an empty reply
    /// can be told apart from a refused one.
    pub fn beginList(self: *Display) void {
        self.list_pending = true;
        self.list_count = 0;
        self.list_refused = false;
    }

    const Route = struct {
        cmd: []const u8,
        run: *const fn (*Display, Message) anyerror!void,
    };

    /// Dispatch table: one entry per server command we render. Shared
    /// handlers appear once per command (whois numerics, send errors) so
    /// `handleServerMessage` is a loop with no `or` chains. Add a row here
    /// instead of a branch when supporting a new numeric.
    const routes = [_]Route{
        .{ .cmd = "375", .run = motd.handleMOTDStart },
        .{ .cmd = "372", .run = motd.handleMOTDLine },
        .{ .cmd = "376", .run = motd.handleMOTDEnd },
        .{ .cmd = "321", .run = list.handleListStart },
        .{ .cmd = "322", .run = list.handleListLine },
        .{ .cmd = "323", .run = list.handleListEnd },
        .{ .cmd = "353", .run = names.handleNames },
        .{ .cmd = "366", .run = names.handleEndOfNames },
        .{ .cmd = "JOIN", .run = events.handleJoin },
        .{ .cmd = "PART", .run = events.handlePart },
        .{ .cmd = "QUIT", .run = events.handleQuit },
        .{ .cmd = "KICK", .run = events.handleKick },
        .{ .cmd = "MODE", .run = events.handleMode },
        .{ .cmd = "INVITE", .run = events.handleInvite },
        .{ .cmd = "NICK", .run = events.handleNick },
        .{ .cmd = "PRIVMSG", .run = chat.handlePrivmsg },
        .{ .cmd = "NOTICE", .run = chat.handleNotice },
        .{ .cmd = "TOPIC", .run = topic.handleTopic },
        .{ .cmd = "331", .run = topic.handleNoTopic },
        .{ .cmd = "332", .run = topic.handleTopicReply },
        .{ .cmd = "333", .run = topic.handleTopicWhoTime },
        .{ .cmd = "311", .run = who.handleWhois },
        .{ .cmd = "312", .run = who.handleWhois },
        .{ .cmd = "313", .run = who.handleWhois },
        .{ .cmd = "317", .run = who.handleWhois },
        .{ .cmd = "318", .run = who.handleWhois },
        .{ .cmd = "319", .run = who.handleWhois },
        .{ .cmd = "301", .run = who.handleWhois },
        .{ .cmd = "352", .run = who.handleWhoLine },
        .{ .cmd = "315", .run = who.handleEndOfWho },
        .{ .cmd = "324", .run = who.handleChannelMode },
        .{ .cmd = "329", .run = who.handleChannelCreated },
        .{ .cmd = "341", .run = who.handleInviteConfirm },
        .{ .cmd = "305", .run = status.handleAwayOff },
        .{ .cmd = "306", .run = status.handleAwayOn },
        .{ .cmd = "001", .run = status.handleWelcome },
        .{ .cmd = "002", .run = status.handleHost },
        .{ .cmd = "003", .run = status.handleCreated },
        .{ .cmd = "004", .run = status.handleServerInfo },
        .{ .cmd = "433", .run = status.handleNickInUse },
        .{ .cmd = "461", .run = status.handleNeedMoreParams },
        .{ .cmd = "401", .run = who.handleSendError },
        .{ .cmd = "403", .run = who.handleSendError },
        .{ .cmd = "404", .run = who.handleSendError },
        .{ .cmd = "441", .run = who.handleSendError },
        .{ .cmd = "442", .run = who.handleSendError },
        .{ .cmd = "443", .run = who.handleSendError },
        .{ .cmd = "473", .run = who.handleSendError },
        .{ .cmd = "474", .run = who.handleSendError },
        .{ .cmd = "475", .run = who.handleSendError },
        .{ .cmd = "421", .run = status.handleUnknownCommand },
    };

    pub fn handleServerMessage(self: *Display, msg: Message) !void {
        for (routes) |r| {
            if (std.mem.eql(u8, msg.command, r.cmd)) return try r.run(self, msg);
        }
        // Other numerics/commands are ignored on purpose.
    }

    /// Local echo of a message we just sent (the server never echoes our
    /// own PRIVMSG back). Mirrors the incoming-message styling.
    pub fn echoSent(self: *Display, target: []const u8, text: []const u8, is_action: bool) void {
        const me = self.current_nick orelse "me";
        // A PM conversation starts in either direction: replaying here (and
        // marking it seen) stops the peer's first reply from replaying the
        // very message we just watched go out. Channels replay on join.
        if (!util.isChannelTarget(target)) self.ensureReplayed(target);
        var nb: [256]u8 = undefined;
        if (util.isChannelTarget(target)) {
            var chb: [256]u8 = undefined;
            if (is_action) {
                util.line("{s} * {s} {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(me, &nb), text });
            } else {
                util.line("{s} <{s}> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(me, &nb), text });
            }
        } else if (is_action) {
            util.line("* {s} {s}\n", .{ fmt.paintNick(me, &nb), text });
        } else {
            util.line("PM to {s}: {s}\n", .{ target, text });
        }

        // Record what we sent, storing actions in the same CTCP form the
        // server sends them so a future replay renders identically.
        if (self.current_nick) |my_nick| {
            if (is_action) {
                var abuf: [1100]u8 = undefined;
                const wrapped = std.fmt.bufPrint(&abuf, "\x01ACTION {s}\x01", .{text}) catch text;
                self.record(target, my_nick, wrapped);
            } else {
                self.record(target, my_nick, text);
            }
        }
    }
};

test "send errors and local echo are displayed without crashing" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    // 404 when messaging a channel we never joined.
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "404",
        .params = .{ "tester", "#ghost" } ++ .{""} ** 13,
        .trailing = "Cannot send to channel (+n)",
    });
    // Unknown command reply.
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "421",
        .params = .{ "tester", "FROB" } ++ .{""} ** 13,
        .trailing = "Unknown command",
    });
    d.echoSent("#zig", "hello", false);
    d.echoSent("alice", "hi", false);
    d.echoSent("#zig", "waves", true);
}

test "kick/mode/invite/who numerics display without crashing" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    try d.handleServerMessage(.{
        .prefix = "op!u@h",
        .command = "KICK",
        .params = .{ "#zig", "bob" } ++ .{""} ** 13,
        .trailing = "spam",
    });
    try d.handleServerMessage(.{
        .prefix = "op!u@h",
        .command = "MODE",
        .params = .{ "#zig", "+o", "bob" } ++ .{""} ** 12,
        .trailing = "spam",
    });
    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "INVITE",
        .params = .{ "tester", "#zig" } ++ .{""} ** 13,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "352",
        .params = .{ "tester", "#zig", "u", "h", "srv", "bob", "H@" } ++ .{""} ** 8,
        .trailing = "0 Bob",
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "315",
        .params = .{ "tester", "#zig" } ++ .{""} ** 13,
        .trailing = "End of WHO",
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "324",
        .params = .{ "tester", "#zig", "+nt" } ++ .{""} ** 12,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "341",
        .params = .{ "tester", "bob", "#zig" } ++ .{""} ** 12,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "306",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "You have been marked as being away",
    });
}

test "resetConnectionState clears what a dropped connection left behind" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    d.collecting_motd = true;
    try d.motd_buffer.appendSlice(t.allocator, "half a motd");
    d.beginList();
    d.list_count = 7;
    d.in_channel_list = true;

    d.resetConnectionState();

    try t.expect(!d.collecting_motd);
    try t.expectEqual(@as(usize, 0), d.motd_buffer.items.len);
    try t.expect(!d.list_pending);
    try t.expect(!d.list_refused);
    try t.expect(!d.in_channel_list);
    try t.expectEqual(@as(usize, 0), d.list_count);
    // The conversation we were in is unaffected.
    try t.expectEqualStrings("tester", d.current_nick.?);
}

test "local status lines print without a server behind them" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    d.info("reconnecting to {s}:{d}…\n", .{ "irc.example.org", 6667 });
    d.err("connection lost\n", .{});
    d.reconnected();
}

test "incoming and outgoing messages are recorded into history" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try d.setHistory(&h, "irc.libera.chat");

    // Incoming channel message + CTCP action.
    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "hello there",
    });
    try d.handleServerMessage(.{
        .prefix = "bob!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "\x01ACTION waves\x01",
    });
    // Incoming PM: recorded under the sender's nick, not our own.
    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "psst",
    });
    // Outgoing channel message + action + PM.
    d.echoSent("#zig", "hi back", false);
    d.echoSent("#zig", "nods", true);
    d.echoSent("carol", "secret", false);

    try t.expectEqual(@as(usize, 1), h.servers.items.len);
    try t.expectEqualStrings("irc.libera.chat", h.servers.items[0].ip);
    try t.expectEqual(@as(usize, 2), h.servers.items[0].channels.items.len);

    const zig = h.servers.items[0].channels.items[0];
    try t.expectEqualStrings("#zig", zig.name);
    try t.expectEqual(@as(usize, 4), zig.messages.items.len);
    try t.expectEqualStrings("alice", zig.messages.items[0].sender);
    try t.expectEqualStrings("hello there", zig.messages.items[0].content);
    try t.expectEqualStrings("bob", zig.messages.items[1].sender);
    try t.expectEqualStrings("\x01ACTION waves\x01", zig.messages.items[1].content);
    try t.expectEqualStrings("tester", zig.messages.items[2].sender);
    try t.expectEqualStrings("hi back", zig.messages.items[2].content);
    try t.expectEqualStrings("tester", zig.messages.items[3].sender);
    try t.expectEqualStrings("\x01ACTION nods\x01", zig.messages.items[3].content);

    const carol = h.servers.items[0].channels.items[1];
    try t.expectEqualStrings("carol", carol.name);
    try t.expectEqual(@as(usize, 2), carol.messages.items.len);
    try t.expectEqualStrings("carol", carol.messages.items[0].sender);
    try t.expectEqualStrings("psst", carol.messages.items[0].content);
    try t.expectEqualStrings("secret", carol.messages.items[1].content);
}

test "history save failures do not break the display" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    // /dev/null is a file, so writing below it always fails (ENOTDIR).
    h.path = try t.allocator.dupe(u8, "/dev/null/history");
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "unsaved",
    });
    d.echoSent("#zig", "also unsaved", false);

    // Reported once, and the message still landed in memory.
    try t.expect(d.history_warned);
    try t.expectEqual(@as(usize, 1), h.servers.items.len);
    try t.expectEqual(@as(usize, 2), h.servers.items[0].channels.items[0].messages.items.len);
}

test "joining a channel replays its saved history exactly once" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try h.addMessage("irc.libera.chat", "#zig", HistMessage.init("alice", 1717000000, "earlier"));
    try h.addMessage("irc.libera.chat", "#zig", HistMessage.init("bob", 1717000001, "and now"));
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "tester!u@h",
        .command = "JOIN",
        .params = .{"#zig"} ++ .{""} ** 14,
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
    try t.expectEqualStrings("#zig", d.replayed.items[0]);
    try t.expectEqualStrings("#zig", d.current_channel.?);

    // Rejoining must not repeat the scrollback.
    try d.handleServerMessage(.{
        .prefix = "tester!u@h",
        .command = "JOIN",
        .params = .{"#zig"} ++ .{""} ** 14,
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
}

test "first PM from a peer replays the saved conversation" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try h.addMessage("irc.libera.chat", "carol", HistMessage.init("carol", 1717000000, "you there?"));
    try h.addMessage("irc.libera.chat", "carol", HistMessage.init("tester", 1717000001, "hi carol"));
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "back online?",
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
    try t.expectEqualStrings("carol", d.replayed.items[0]);

    // Later messages from the same peer don't replay again.
    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "and again",
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);

    // And both new messages were recorded on top of the two saved ones.
    try t.expectEqual(@as(usize, 4), d.savedFor("carol").?.len);
}

test "PM conversation replays once, whichever side speaks first" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try h.addMessage("irc.libera.chat", "carol", HistMessage.init("carol", 1717000000, "earlier"));
    try h.addMessage("irc.libera.chat", "carol", HistMessage.init("tester", 1717000001, "sure"));
    try d.setHistory(&h, "irc.libera.chat");

    // We speak first: history shows, then our live line is recorded.
    d.echoSent("carol", "hi again", false);
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
    try t.expectEqual(@as(usize, 3), d.savedFor("carol").?.len);

    // Her reply must not replay the message we just watched go out.
    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "welcome back",
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
    try t.expectEqual(@as(usize, 4), d.savedFor("carol").?.len);
}

test "replayWindow keeps only the newest messages" {
    const t = std.testing;
    var many: [60]HistMessage = undefined;
    for (&many, 0..) |*m, i| m.* = HistMessage.init("alice", @intCast(i), "x");

    const win = Display.replayWindow(&many);
    try t.expectEqual(@as(usize, 50), win.len);
    try t.expectEqual(@as(i64, 10), win[0].timestamp);
    try t.expectEqual(@as(i64, 59), win[49].timestamp);

    var few: [3]HistMessage = undefined;
    for (&few, 0..) |*m, i| m.* = HistMessage.init("alice", @intCast(i), "y");
    const small = Display.replayWindow(&few);
    try t.expectEqual(@as(usize, 3), small.len);
    try t.expectEqual(@as(i64, 0), small[0].timestamp);
}

test "savedFor returns null without history or for unknown conversations" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try t.expect(d.savedFor("#zig") == null);

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try h.addMessage("irc.libera.chat", "#zig", HistMessage.init("alice", 1, "hi"));
    try d.setHistory(&h, "irc.libera.chat");
    try t.expect(d.savedFor("#zig") != null);
    try t.expect(d.savedFor("#rust") == null);
    try d.setHistory(&h, "irc.oftc.net");
    try t.expect(d.savedFor("#zig") == null);
}

test "dispatch ignores unknown commands and has no duplicate routes" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    // Unknown numerics/commands are ignored on purpose, never an error.
    try d.handleServerMessage(.{ .command = "999", .trailing = "whatever" });
    try d.handleServerMessage(.{ .command = "BOGUS" });

    // Every command maps to exactly one row: no duplicates to diverge.
    for (Display.routes, 0..) |a, i| {
        for (Display.routes[0..i]) |b| {
            try t.expect(!std.mem.eql(u8, a.cmd, b.cmd));
        }
    }
    // Grouped handlers stay covered after refactor.
    var whois_rows: usize = 0;
    var send_err_rows: usize = 0;
    for (Display.routes) |r| {
        if (r.run == who.handleWhois) whois_rows += 1;
        if (r.run == who.handleSendError) send_err_rows += 1;
    }
    try t.expectEqual(@as(usize, 7), whois_rows);
    try t.expectEqual(@as(usize, 9), send_err_rows);
}
