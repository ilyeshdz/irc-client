const std = @import("std");
const out = @import("out.zig");
const Message = @import("irc-client").Message;
const fmt = @import("format.zig");
const hist = @import("history.zig");
const History = hist.History;
const HistMessage = hist.Message;

/// Newest saved messages printed when a conversation is first shown.
const max_replay = 50;

/// Print a normal line prefixed with a dim timestamp.
fn line(comptime f: []const u8, args: anytype) void {
    var tsb: [16]u8 = undefined;
    var tss: [32]u8 = undefined;
    out.print("{s} ", .{fmt.dimTimestamp(&tsb, &tss)});
    out.print(f, args);
}

/// Print a channel event (join/part/quit/...) with a dim glyph prefix.
fn event(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        out.print("{s} {s}*{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.dim, fmt.reset });
        out.print(f, args);
    } else {
        line("* " ++ f, args);
    }
}

fn errLine(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        out.print("{s} {s}✗{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.red, fmt.reset });
        out.print(f, args);
    } else {
        line("error: " ++ f, args);
    }
}

/// Green ✓ status line when colors are on, plain timestamped line otherwise.
fn statusLine(
    comptime colored_fmt: []const u8,
    colored_args: anytype,
    comptime plain_fmt: []const u8,
    plain_args: anytype,
) void {
    if (fmt.isEnabled()) {
        out.print(colored_fmt, colored_args);
    } else {
        line(plain_fmt, plain_args);
    }
}

pub const Display = struct {
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

    fn record(self: *Display, conv: []const u8, sender: []const u8, content: []const u8) void {
        const h = self.history orelse return;
        const ip = self.server_ip orelse return;
        h.addMessage(ip, conv, .{
            .sender = sender,
            .timestamp = fmt.nowSecs() orelse 0,
            .content = content,
        }) catch {
            if (!self.history_warned) {
                self.history_warned = true;
                errLine("could not save history to disk\n", .{});
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
    fn ensureReplayed(self: *Display, conv: []const u8) void {
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
        const action = parseAction(m.content);
        const content = action orelse m.content;

        if (isChannelTarget(conv)) {
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
        line(f, args);
    }

    /// Local error line (no server behind it).
    pub fn err(_: *Display, comptime f: []const u8, args: anytype) void {
        errLine(f, args);
    }

    /// The TCP connection is back; the server's 001 prints separately.
    pub fn reconnected(_: *Display) void {
        statusLine(
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

    fn isCmd(msg: Message, name: []const u8) bool {
        return std.mem.eql(u8, msg.command, name);
    }

    pub fn handleServerMessage(self: *Display, msg: Message) !void {
        if (isCmd(msg, "375")) {
            try self.handleMOTDStart(msg);
        } else if (isCmd(msg, "372")) {
            try self.handleMOTDLine(msg);
        } else if (isCmd(msg, "376")) {
            try self.handleMOTDEnd(msg);
        } else if (isCmd(msg, "321")) {
            self.handleListStart();
        } else if (isCmd(msg, "322")) {
            self.handleListLine(msg);
        } else if (isCmd(msg, "323")) {
            self.handleListEnd();
        } else if (isCmd(msg, "353")) {
            self.handleNames(msg);
        } else if (isCmd(msg, "366")) {
            self.handleEndOfNames(msg);
        } else if (isCmd(msg, "JOIN")) {
            self.handleJoin(msg);
        } else if (isCmd(msg, "PART")) {
            self.handlePart(msg);
        } else if (isCmd(msg, "QUIT")) {
            self.handleQuit(msg);
        } else if (isCmd(msg, "KICK")) {
            self.handleKick(msg);
        } else if (isCmd(msg, "MODE")) {
            self.handleMode(msg);
        } else if (isCmd(msg, "INVITE")) {
            self.handleInvite(msg);
        } else if (isCmd(msg, "NICK")) {
            self.handleNick(msg);
        } else if (isCmd(msg, "PRIVMSG")) {
            self.handlePrivmsg(msg);
        } else if (isCmd(msg, "NOTICE")) {
            self.handleNotice(msg);
        } else if (isCmd(msg, "TOPIC")) {
            self.handleTopic(msg);
        } else if (isCmd(msg, "331")) {
            self.handleNoTopic(msg);
        } else if (isCmd(msg, "332")) {
            self.handleTopicReply(msg);
        } else if (isCmd(msg, "333")) {
            self.handleTopicWhoTime(msg);
        } else if (isCmd(msg, "311") or isCmd(msg, "312") or isCmd(msg, "313") or
            isCmd(msg, "317") or isCmd(msg, "318") or isCmd(msg, "319") or isCmd(msg, "301"))
        {
            self.handleWhois(msg);
        } else if (isCmd(msg, "352")) {
            self.handleWhoLine(msg);
        } else if (isCmd(msg, "315")) {
            self.handleEndOfWho(msg);
        } else if (isCmd(msg, "324")) {
            self.handleChannelMode(msg);
        } else if (isCmd(msg, "329")) {
            self.handleChannelCreated(msg);
        } else if (isCmd(msg, "341")) {
            self.handleInviteConfirm(msg);
        } else if (isCmd(msg, "305")) {
            line("You are no longer marked as away\n", .{});
        } else if (isCmd(msg, "306")) {
            line("You are now marked as away\n", .{});
        } else if (isCmd(msg, "001")) {
            statusLine(
                "{s}✓ connected{s} {s}\n",
                .{ fmt.green, fmt.reset, msg.trailing },
                "Connected: {s}\n",
                .{msg.trailing},
            );
        } else if (isCmd(msg, "002")) {
            line("Host: {s}\n", .{msg.trailing});
        } else if (isCmd(msg, "003")) {
            line("Created: {s}\n", .{msg.trailing});
        } else if (isCmd(msg, "004")) {
            if (msg.params[0].len > 0) line("Server: {s}\n", .{msg.params[0]});
        } else if (isCmd(msg, "433")) {
            if (msg.params[1].len > 0) {
                var nb: [256]u8 = undefined;
                errLine("Nickname {s} is already in use\n", .{fmt.paintNick(msg.params[1], &nb)});
            }
        } else if (isCmd(msg, "461")) {
            if (msg.params[1].len > 0) errLine("{s}: not enough parameters\n", .{msg.params[1]});
        } else if (isCmd(msg, "401") or isCmd(msg, "403") or isCmd(msg, "404") or
            isCmd(msg, "441") or isCmd(msg, "442") or isCmd(msg, "443") or
            isCmd(msg, "473") or isCmd(msg, "474") or isCmd(msg, "475"))
        {
            self.handleSendError(msg);
        } else if (isCmd(msg, "421")) {
            if (msg.params[1].len > 0) {
                errLine("{s}: {s}\n", .{ msg.params[1], msg.trailing });
            } else if (msg.trailing.len > 0) {
                errLine("{s}\n", .{msg.trailing});
            }
        }
        // Other numerics/commands are ignored on purpose.
    }

    // --- MOTD (375/372/376) ---

    fn handleMOTDStart(self: *Display, msg: Message) !void {
        self.collecting_motd = true;
        self.motd_buffer.clearRetainingCapacity();
        if (msg.trailing.len > 0) {
            try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
            try self.motd_buffer.appendSlice(self.allocator, "\n");
        }
    }

    fn handleMOTDLine(self: *Display, msg: Message) !void {
        if (self.collecting_motd and msg.trailing.len > 0) {
            try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
            try self.motd_buffer.appendSlice(self.allocator, "\n");
        }
    }

    fn handleMOTDEnd(self: *Display, msg: Message) !void {
        if (!self.collecting_motd) return;
        self.collecting_motd = false;
        if (msg.trailing.len > 0) {
            try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
            try self.motd_buffer.appendSlice(self.allocator, "\n");
        }
        self.printMOTD();
    }

    fn printMOTD(self: *Display) void {
        const motd = std.mem.trimEnd(u8, self.motd_buffer.items, "\n");
        if (fmt.isEnabled()) {
            out.print("\n{s}╭─ MOTD ─────────────{s}\n", .{ fmt.cyan, fmt.reset });
        } else {
            out.print("\n--- MOTD ---\n", .{});
        }
        if (motd.len > 0) {
            var it = std.mem.splitScalar(u8, motd, '\n');
            while (it.next()) |l| {
                if (fmt.isEnabled()) {
                    out.print("{s}│{s} {s}\n", .{ fmt.cyan, fmt.reset, l });
                } else {
                    out.print("{s}\n", .{l});
                }
            }
        } else {
            line("(empty)\n", .{});
        }
        if (fmt.isEnabled()) {
            out.print("{s}╰────────────────────{s}\n\n", .{ fmt.cyan, fmt.reset });
        } else {
            out.print("------------\n\n", .{});
        }
    }

    // --- LIST (321/322/323) ---

    fn handleListStart(self: *Display) void {
        self.in_channel_list = true;
        if (fmt.isEnabled()) {
            out.print("\n{s}{s}channels{s}  {s}users  topic{s}\n", .{ fmt.bold, fmt.cyan, fmt.reset, fmt.dim, fmt.reset });
            out.print("{s}─────────────────────────────{s}\n", .{ fmt.dim, fmt.reset });
        } else {
            out.print("\n--- Channels ---\n", .{});
        }
    }

    /// Called when the user requests a channel list, so an empty reply
    /// can be told apart from a refused one.
    pub fn beginList(self: *Display) void {
        self.list_pending = true;
        self.list_count = 0;
        self.list_refused = false;
    }

    fn handleListLine(self: *Display, msg: Message) void {
        if (!self.in_channel_list and !self.list_pending) return;
        // params: [nick, channel, usercount]
        const channel = msg.params[1];
        const users = msg.params[2];
        if (channel.len == 0) return;
        self.list_count += 1;
        const topic = if (msg.trailing.len > 0) msg.trailing else "(no topic)";
        var chb: [256]u8 = undefined;
        line("{s}  {s}  {s}\n", .{ fmt.paintChannel(channel, &chb), users, topic });
    }

    fn handleListEnd(self: *Display) void {
        if (self.in_channel_list) {
            self.in_channel_list = false;
            if (fmt.isEnabled()) {
                out.print("{s}─────────────────────────────{s}\n\n", .{ fmt.dim, fmt.reset });
            } else {
                out.print("------------------\n\n", .{});
            }
        } else if (self.list_refused) {
            errLine("Channel listing refused by the server (LIST is restricted here)\n\n", .{});
        } else if (self.list_count == 0) {
            line("No channels found\n\n", .{});
        }
        self.list_pending = false;
        self.list_refused = false;
    }

    /// Detects server notices telling us the channel listing was refused
    /// (e.g. IRCnet's "/list is deprecated" notice) while a list is pending.
    fn noteListRefusal(self: *Display, text: []const u8) void {
        if (!self.list_pending or self.list_count > 0) return;
        if (containsCaseInsensitive(text, "deprecat") or
            containsCaseInsensitive(text, "too large") or
            containsCaseInsensitive(text, "truncat"))
        {
            self.list_refused = true;
        }
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var match = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    // --- NAMES (353/366) ---

    fn handleNames(_: *Display, msg: Message) void {
        // params: [nick, =, channel]
        if (msg.params[2].len == 0) return;
        var chb: [256]u8 = undefined;
        line("Users in {s}: {s}\n", .{ fmt.paintChannel(msg.params[2], &chb), msg.trailing });
    }

    fn handleEndOfNames(_: *Display, msg: Message) void {
        if (msg.params[1].len == 0) return;
        var chb: [256]u8 = undefined;
        line("End of /names for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
    }

    // --- Channel events ---

    fn nickOnly(prefix: []const u8) []const u8 {
        var it = std.mem.splitScalar(u8, prefix, '!');
        return it.next() orelse prefix;
    }

    /// Reason text for commands like KICK/PART/QUIT/TOPIC: servers may send a
    /// single-word reason *without* the ':' prefix, in which case the parser
    /// leaves it in params[idx] instead of trailing.
    fn reasonOf(msg: Message, idx: usize) []const u8 {
        if (msg.trailing.len > 0) return msg.trailing;
        if (idx < msg.params.len) return msg.params[idx];
        return "";
    }

    fn isChannelTarget(target: []const u8) bool {
        return std.mem.startsWith(u8, target, "#") or std.mem.startsWith(u8, target, "&");
    }

    fn handleJoin(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        const channel = msg.params[0];
        if (channel.len == 0) return;

        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, nick, my_nick)) {
                var chb: [256]u8 = undefined;
                event("You joined {s}\n", .{fmt.paintChannel(channel, &chb)});
                self.setCurrentChannel(channel) catch {};
                line("now talking in {s} — type a message, /help for commands\n", .{fmt.paintChannel(channel, &chb)});
                self.ensureReplayed(channel);
            } else {
                var nb: [256]u8 = undefined;
                var chb: [256]u8 = undefined;
                event("{s} joined {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
            }
        }
    }

    fn handlePart(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        const channel = msg.params[0];
        if (channel.len == 0) return;

        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, nick, my_nick)) {
                var chb: [256]u8 = undefined;
                event("You left {s}\n", .{fmt.paintChannel(channel, &chb)});
                if (self.current_channel) |current| {
                    if (std.mem.eql(u8, current, channel)) self.setCurrentChannel(null) catch {};
                }
            } else if (reasonOf(msg, 1).len > 0) {
                var nb: [256]u8 = undefined;
                var chb: [256]u8 = undefined;
                event("{s} left {s} ({s})\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb), reasonOf(msg, 1) });
            } else {
                var nb: [256]u8 = undefined;
                var chb: [256]u8 = undefined;
                event("{s} left {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
            }
        }
    }

    fn handleQuit(_: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        var nb: [256]u8 = undefined;
        if (reasonOf(msg, 0).len > 0) {
            event("{s} quit ({s})\n", .{ fmt.paintNick(nick, &nb), reasonOf(msg, 0) });
        } else {
            event("{s} quit\n", .{fmt.paintNick(nick, &nb)});
        }
    }

    fn handleKick(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const kicker = nickOnly(prefix);
        const channel = msg.params[0];
        const target = msg.params[1];
        if (channel.len == 0 or target.len == 0) return;
        var kb: [256]u8 = undefined;
        var tb: [256]u8 = undefined;
        var chb: [256]u8 = undefined;
        if (reasonOf(msg, 2).len > 0) {
            event("{s} kicked {s} from {s} ({s})\n", .{
                fmt.paintNick(kicker, &kb),
                fmt.paintNick(target, &tb),
                fmt.paintChannel(channel, &chb),
                reasonOf(msg, 2),
            });
        } else {
            event("{s} kicked {s} from {s}\n", .{
                fmt.paintNick(kicker, &kb),
                fmt.paintNick(target, &tb),
                fmt.paintChannel(channel, &chb),
            });
        }
        // We were kicked: stop targeting this channel.
        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, target, my_nick)) {
                if (self.current_channel) |current| {
                    if (std.mem.eql(u8, current, channel)) self.setCurrentChannel(null) catch {};
                }
            }
        }
    }

    fn handleMode(_: *Display, msg: Message) void {
        const target = msg.params[0];
        const modes = msg.params[1];
        if (target.len == 0 or modes.len == 0) return;
        var argb: [256]u8 = undefined;
        const args = joinParams(msg.params[2..], &argb);
        if (msg.prefix) |prefix| {
            const nick = nickOnly(prefix);
            var nb: [256]u8 = undefined;
            if (args.len > 0) {
                event("{s} set mode {s} {s} on {s}\n", .{ fmt.paintNick(nick, &nb), modes, args, target });
            } else {
                event("{s} set mode {s} on {s}\n", .{ fmt.paintNick(nick, &nb), modes, target });
            }
        } else if (args.len > 0) {
            line("Mode {s} {s} on {s}\n", .{ modes, args, target });
        } else {
            line("Mode {s} on {s}\n", .{ modes, target });
        }
    }

    fn handleInvite(_: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        // INVITE params: [me, channel] on most servers (target first on some).
        const channel = if (msg.params[1].len > 0) msg.params[1] else msg.trailing;
        if (channel.len == 0) return;
        var nb: [256]u8 = undefined;
        var chb: [256]u8 = undefined;
        event("{s} invited you to {s} — /join {s} to accept\n", .{
            fmt.paintNick(nick, &nb),
            fmt.paintChannel(channel, &chb),
            channel,
        });
    }

    /// Join space-separated params (skipping empties) for MODE display.
    fn joinParams(params: []const []const u8, buf: *[256]u8) []const u8 {
        var len: usize = 0;
        for (params) |p| {
            if (p.len == 0) continue;
            const sep: usize = if (len > 0) 1 else 0;
            if (len + sep + p.len > buf.len) break;
            if (sep > 0) {
                buf[len] = ' ';
                len += 1;
            }
            @memcpy(buf[len .. len + p.len], p);
            len += p.len;
        }
        return buf[0..len];
    }

    fn handleNick(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const old_nick = nickOnly(prefix);
        const new_nick = msg.params[0];
        if (new_nick.len == 0) return;

        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, old_nick, my_nick)) {
                var nb: [256]u8 = undefined;
                event("You are now known as {s}\n", .{fmt.paintNick(new_nick, &nb)});
                self.setCurrentNick(new_nick) catch {};
            } else {
                var ob: [256]u8 = undefined;
                var nb: [256]u8 = undefined;
                event("{s} is now known as {s}\n", .{ fmt.paintNick(old_nick, &ob), fmt.paintNick(new_nick, &nb) });
            }
        }
    }

    fn handlePrivmsg(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        const target = msg.params[0];
        if (target.len == 0) return;

        // Persist under the channel, or under the peer's nick for PMs, so
        // a private conversation is one history entry per counterpart.
        var conv = target;
        if (!isChannelTarget(target)) {
            if (self.current_nick) |my_nick| {
                if (std.mem.eql(u8, target, my_nick)) {
                    conv = nick;
                    // PMs have no join event: show the saved conversation
                    // right before the first message of it we see.
                    self.ensureReplayed(nick);
                }
            }
        }
        self.record(conv, nick, msg.trailing);

        if (parseAction(msg.trailing)) |action| {
            var nb: [256]u8 = undefined;
            if (isChannelTarget(target)) {
                var chb: [256]u8 = undefined;
                line("{s} * {s} {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), action });
            } else {
                line("* {s} {s}\n", .{ fmt.paintNick(nick, &nb), action });
            }
            return;
        }

        var nb: [256]u8 = undefined;
        if (isChannelTarget(target)) {
            var chb: [256]u8 = undefined;
            line("{s} <{s}> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), msg.trailing });
        } else if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, target, my_nick)) {
                line("PM from {s}: {s}\n", .{ fmt.paintNick(nick, &nb), msg.trailing });
            } else {
                line("PM to {s}: {s}\n", .{ target, msg.trailing });
            }
        }
    }

    fn handleNotice(self: *Display, msg: Message) void {
        const target = msg.params[0];
        if (target.len == 0) return;
        self.noteListRefusal(msg.trailing);
        if (self.current_nick) |my_nick| {
            if (!std.mem.eql(u8, target, my_nick) and !isChannelTarget(target)) return;
        }
        if (msg.prefix) |prefix| {
            const nick = nickOnly(prefix);
            var nb: [256]u8 = undefined;
            if (isChannelTarget(target)) {
                var chb: [256]u8 = undefined;
                line("{s} -{s}- {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(nick, &nb), msg.trailing });
            } else {
                line("-{s}- {s}\n", .{ fmt.paintNick(nick, &nb), msg.trailing });
            }
        } else {
            line("-server- {s}\n", .{msg.trailing});
        }
    }

    fn handleTopic(_: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const channel = msg.params[0];
        if (channel.len == 0) return;
        var chb: [256]u8 = undefined;
        var nb: [256]u8 = undefined;
        event("Topic for {s} changed by {s}: {s}\n", .{ fmt.paintChannel(channel, &chb), fmt.paintNick(nickOnly(prefix), &nb), reasonOf(msg, 1) });
    }

    fn handleTopicReply(_: *Display, msg: Message) void {
        // params: [nick, channel]
        if (msg.params[1].len == 0) return;
        var chb: [256]u8 = undefined;
        if (msg.trailing.len > 0) {
            line("Topic for {s}: {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), msg.trailing });
        } else {
            line("No topic set for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
        }
    }

    fn handleNoTopic(_: *Display, msg: Message) void {
        // params: [nick, channel]
        if (msg.params[1].len == 0) return;
        var chb: [256]u8 = undefined;
        line("No topic set for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
    }

    fn handleTopicWhoTime(_: *Display, msg: Message) void {
        // params: [nick, channel, set-by, timestamp]
        if (msg.params[1].len == 0) return;
        const set_by = msg.params[2];
        const when = msg.params[3];
        var chb: [256]u8 = undefined;
        var nb: [256]u8 = undefined;
        if (set_by.len > 0 and when.len > 0) {
            line("Topic for {s} set by {s} at {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), fmt.paintNick(set_by, &nb), when });
        } else if (set_by.len > 0) {
            line("Topic for {s} set by {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), fmt.paintNick(set_by, &nb) });
        }
    }

    fn handleWhois(_: *Display, msg: Message) void {
        // params[1] is the queried nick for all these numerics.
        const nick = msg.params[1];
        var nb: [256]u8 = undefined;
        const styled_nick = fmt.paintNick(nick, &nb);
        if (std.mem.eql(u8, msg.command, "311")) {
            // [me, nick, user, host] + realname
            line("• {s} is {s}@{s} ({s})\n", .{ styled_nick, msg.params[2], msg.params[3], msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "312")) {
            // [me, nick, server] + server info
            line("• {s} on {s} ({s})\n", .{ styled_nick, msg.params[2], msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "313")) {
            line("• {s} {s}\n", .{ styled_nick, msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "317")) {
            // [me, nick, idle-secs] + signon info in trailing
            line("• {s} idle {s}s {s}\n", .{ styled_nick, msg.params[2], msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "319")) {
            line("• {s} on {s}\n", .{ styled_nick, msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "301")) {
            line("• {s} is away: {s}\n", .{ styled_nick, msg.trailing });
        } else if (std.mem.eql(u8, msg.command, "318")) {
            line("End of /whois for {s}\n", .{styled_nick});
        }
    }

    fn handleWhoLine(_: *Display, msg: Message) void {
        // 352 params: [me, channel, user, host, server, nick, flags] + hopcount realname
        const nick = msg.params[5];
        if (nick.len == 0) return;
        var nb: [256]u8 = undefined;
        const flags = msg.params[6];
        const away = std.mem.indexOfScalar(u8, flags, 'G') != null;
        if (msg.trailing.len > 0) {
            line("• {s} {s}@{s} [{s}]{s}\n", .{
                fmt.paintNick(nick, &nb),
                msg.params[2],
                msg.params[3],
                flags,
                if (away) " (away)" else "",
            });
        } else {
            line("• {s} [{s}]{s}\n", .{ fmt.paintNick(nick, &nb), flags, if (away) " (away)" else "" });
        }
    }

    fn handleEndOfWho(_: *Display, msg: Message) void {
        // 315 params: [me, target]
        if (msg.params[1].len == 0) return;
        line("End of /who for {s}\n", .{msg.params[1]});
    }

    fn handleChannelMode(_: *Display, msg: Message) void {
        // 324 params: [me, channel, modes, ...args]
        const channel = msg.params[1];
        const modes = msg.params[2];
        if (channel.len == 0) return;
        var chb: [256]u8 = undefined;
        var argb: [256]u8 = undefined;
        const args = joinParams(msg.params[3..], &argb);
        if (modes.len > 0 and args.len > 0) {
            line("Modes for {s}: {s} {s}\n", .{ fmt.paintChannel(channel, &chb), modes, args });
        } else if (modes.len > 0) {
            line("Modes for {s}: {s}\n", .{ fmt.paintChannel(channel, &chb), modes });
        } else {
            line("No modes set on {s}\n", .{fmt.paintChannel(channel, &chb)});
        }
    }

    fn handleChannelCreated(_: *Display, msg: Message) void {
        // 329 params: [me, channel, timestamp]
        if (msg.params[1].len == 0) return;
        var chb: [256]u8 = undefined;
        if (msg.params[2].len > 0) {
            line("{s} created at {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), msg.params[2] });
        }
    }

    fn handleInviteConfirm(_: *Display, msg: Message) void {
        // 341 params: [me, nick, channel]
        const nick = msg.params[1];
        const channel = msg.params[2];
        if (nick.len == 0) return;
        var nb: [256]u8 = undefined;
        if (channel.len > 0) {
            var chb: [256]u8 = undefined;
            line("{s} invited to {s}\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb) });
        } else {
            line("{s} invited\n", .{fmt.paintNick(nick, &nb)});
        }
    }

    fn parseAction(trailing: []const u8) ?[]const u8 {
        // CTCP ACTION is wrapped in \x01...\x01
        if (trailing.len < 9) return null;
        if (trailing[0] != 0x01 or trailing[trailing.len - 1] != 0x01) return null;
        const inner = trailing[1 .. trailing.len - 1];
        const prefix = "ACTION ";
        if (!std.mem.startsWith(u8, inner, prefix)) return null;
        return inner[prefix.len..];
    }

    /// Show server rejections for messages we tried to send, e.g.
    /// 404 "Cannot send to channel" when not joined. params[1] is the
    /// target, trailing carries the human-readable reason.
    fn handleSendError(_: *Display, msg: Message) void {
        const target = msg.params[1];
        if (target.len > 0 and msg.trailing.len > 0) {
            errLine("{s}: {s}\n", .{ target, msg.trailing });
        } else if (msg.trailing.len > 0) {
            errLine("{s}\n", .{msg.trailing});
        } else if (target.len > 0) {
            errLine("{s}: command failed ({s})\n", .{ target, msg.command });
        }
    }

    /// Local echo of a message we just sent (the server never echoes our
    /// own PRIVMSG back). Mirrors the incoming-message styling.
    pub fn echoSent(self: *Display, target: []const u8, text: []const u8, is_action: bool) void {
        const me = self.current_nick orelse "me";
        // A PM conversation starts in either direction: replaying here (and
        // marking it seen) stops the peer's first reply from replaying the
        // very message we just watched go out. Channels replay on join.
        if (!isChannelTarget(target)) self.ensureReplayed(target);
        var nb: [256]u8 = undefined;
        if (isChannelTarget(target)) {
            var chb: [256]u8 = undefined;
            if (is_action) {
                line("{s} * {s} {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(me, &nb), text });
            } else {
                line("{s} <{s}> {s}\n", .{ fmt.paintChannel(target, &chb), fmt.paintNick(me, &nb), text });
            }
        } else if (is_action) {
            line("* {s} {s}\n", .{ fmt.paintNick(me, &nb), text });
        } else {
            line("PM to {s}: {s}\n", .{ target, text });
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

test "being kicked clears the current channel" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    try d.setCurrentChannel("#zig");
    try d.handleServerMessage(.{
        .prefix = "op!u@h",
        .command = "KICK",
        .params = .{ "#zig", "tester" } ++ .{""} ** 13,
        .trailing = "bye",
    });
    try std.testing.expect(d.current_channel == null);
}

test "colon-less single-word reasons fall back to params" {
    // Servers may send `KICK #c nick bye` without ':'; the parser then
    // leaves "bye" in params[2] instead of trailing.
    const parsed = try Message.parse(":op!u@h KICK #zig bob bye");
    try std.testing.expectEqualStrings("", parsed.trailing);
    try std.testing.expectEqualStrings("bye", Display.reasonOf(parsed, 2));

    const quit = try Message.parse(":bob!u@h QUIT leaving");
    try std.testing.expectEqualStrings("leaving", Display.reasonOf(quit, 0));

    const part = try Message.parse(":bob!u@h PART #zig ciao");
    try std.testing.expectEqualStrings("ciao", Display.reasonOf(part, 1));
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

test "refused LIST reports refusal instead of empty list" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    d.beginList();
    // IRCnet-style deprecation notice received while the list is pending.
    try d.handleServerMessage(.{
        .prefix = "ircnet.tngnet.nl",
        .command = "NOTICE",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "Usage of /list for listing all channels is deprecated.",
    });
    try std.testing.expect(d.list_refused);
    // Server ends the list without any channel.
    try d.handleServerMessage(.{
        .prefix = "ircnet.tngnet.nl",
        .command = "323",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "End of LIST",
    });
    try std.testing.expect(!d.list_pending);
}

test "empty LIST without refusal stays a plain empty list" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    d.beginList();
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "323",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "End of LIST",
    });
    try std.testing.expect(!d.list_pending);
    try std.testing.expect(!d.list_refused);
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
