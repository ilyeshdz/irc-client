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
    // Handlers in `display/` are free functions taking `*Display`; fields
    // are visible wherever the type is, only methods need `pub`.
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

    fn replayWindow(messages: []const HistMessage) []const HistMessage {
        if (messages.len <= max_replay) return messages;
        return messages[messages.len - max_replay ..];
    }

    /// Print saved history exactly once per session: rejoins and chatty PMs
    /// must not repeat the scrollback.
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

    /// One saved message, keeping its original send time.
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

    pub fn info(_: *Display, comptime f: []const u8, args: anytype) void {
        util.line(f, args);
    }

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

    /// Drop MOTD/LIST state owned by the dead connection.
    pub fn resetConnectionState(self: *Display) void {
        self.collecting_motd = false;
        self.motd_buffer.clearRetainingCapacity();
        self.in_channel_list = false;
        self.list_pending = false;
        self.list_count = 0;
        self.list_refused = false;
    }

    /// Mark a user-requested list, so an empty reply differs from a refused one.
    pub fn beginList(self: *Display) void {
        self.list_pending = true;
        self.list_count = 0;
        self.list_refused = false;
    }

    const Route = struct {
        cmd: []const u8,
        run: *const fn (*Display, Message) anyerror!void,
    };

    /// One row per server command we render. Shared handlers appear once per
    /// command so dispatch stays a loop; add a row for each new numeric.
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

    /// Echo of a message we just sent: the server never echoes our own
    /// PRIVMSG back.
    pub fn echoSent(self: *Display, target: []const u8, text: []const u8, is_action: bool) void {
        const me = self.current_nick orelse "me";
        // A PM starts in either direction: replay here, or the peer's first
        // reply replays the message we just watched go out.
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

        // Store actions in the server's CTCP form so replays render identically.
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

    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "and again",
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);

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
