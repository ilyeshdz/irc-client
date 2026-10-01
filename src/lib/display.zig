const std = @import("std");
const Message = @import("message.zig").Message;
const fmt = @import("format.zig");

/// Print a normal line prefixed with a dim timestamp.
fn line(comptime f: []const u8, args: anytype) void {
    var tsb: [16]u8 = undefined;
    var tss: [32]u8 = undefined;
    std.debug.print("{s} ", .{fmt.dimTimestamp(&tsb, &tss)});
    std.debug.print(f, args);
}

/// Print a channel event (join/part/quit/...) with a dim glyph prefix.
fn event(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        std.debug.print("{s} {s}*{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.dim, fmt.reset });
        std.debug.print(f, args);
    } else {
        line("* " ++ f, args);
    }
}

fn errLine(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        std.debug.print("{s} {s}✗{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.red, fmt.reset });
        std.debug.print(f, args);
    } else {
        line("error: " ++ f, args);
    }
}

pub const Display = struct {
    allocator: std.mem.Allocator,
    motd_buffer: std.ArrayList(u8),
    collecting_motd: bool,
    motd_complete: bool,
    in_channel_list: bool,
    list_pending: bool,
    list_count: usize,
    list_refused: bool,
    current_channel: ?[]const u8,
    current_nick: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !Display {
        const motd_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        return Display{
            .allocator = allocator,
            .motd_buffer = motd_buffer,
            .collecting_motd = false,
            .motd_complete = false,
            .in_channel_list = false,
            .list_pending = false,
            .list_count = 0,
            .list_refused = false,
            .current_channel = null,
            .current_nick = null,
        };
    }

    pub fn deinit(self: *Display) void {
        self.motd_buffer.deinit(self.allocator);
        if (self.current_channel) |c| self.allocator.free(c);
        if (self.current_nick) |n| self.allocator.free(n);
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

    pub fn isMOTDComplete(self: *Display) bool {
        return self.motd_complete;
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
        } else if (isCmd(msg, "001")) {
            if (fmt.isEnabled()) {
                std.debug.print("{s}✓ connected{s} {s}\n", .{ fmt.green, fmt.reset, msg.trailing });
            } else {
                line("Connected: {s}\n", .{msg.trailing});
            }
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
        self.motd_complete = false;
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
        self.motd_complete = true;
        if (msg.trailing.len > 0) {
            try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
            try self.motd_buffer.appendSlice(self.allocator, "\n");
        }
        self.printMOTD();
    }

    fn printMOTD(self: *Display) void {
        const motd = std.mem.trimEnd(u8, self.motd_buffer.items, "\n");
        if (fmt.isEnabled()) {
            std.debug.print("\n{s}╭─ MOTD ─────────────{s}\n", .{ fmt.cyan, fmt.reset });
        } else {
            std.debug.print("\n--- MOTD ---\n", .{});
        }
        if (motd.len > 0) {
            var it = std.mem.splitScalar(u8, motd, '\n');
            while (it.next()) |l| {
                if (fmt.isEnabled()) {
                    std.debug.print("{s}│{s} {s}\n", .{ fmt.cyan, fmt.reset, l });
                } else {
                    std.debug.print("{s}\n", .{l});
                }
            }
        } else {
            line("(empty)\n", .{});
        }
        if (fmt.isEnabled()) {
            std.debug.print("{s}╰────────────────────{s}\n\n", .{ fmt.cyan, fmt.reset });
        } else {
            std.debug.print("------------\n\n", .{});
        }
    }

    // --- LIST (321/322/323) ---

    fn handleListStart(self: *Display) void {
        self.in_channel_list = true;
        if (fmt.isEnabled()) {
            std.debug.print("\n{s}{s}channels{s}  {s}users  topic{s}\n", .{ fmt.bold, fmt.cyan, fmt.reset, fmt.dim, fmt.reset });
            std.debug.print("{s}─────────────────────────────{s}\n", .{ fmt.dim, fmt.reset });
        } else {
            std.debug.print("\n--- Channels ---\n", .{});
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
                std.debug.print("{s}─────────────────────────────{s}\n\n", .{ fmt.dim, fmt.reset });
            } else {
                std.debug.print("------------------\n\n", .{});
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
            } else if (msg.trailing.len > 0) {
                var nb: [256]u8 = undefined;
                var chb: [256]u8 = undefined;
                event("{s} left {s} ({s})\n", .{ fmt.paintNick(nick, &nb), fmt.paintChannel(channel, &chb), msg.trailing });
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
        if (msg.trailing.len > 0) {
            event("{s} quit ({s})\n", .{ fmt.paintNick(nick, &nb), msg.trailing });
        } else {
            event("{s} quit\n", .{fmt.paintNick(nick, &nb)});
        }
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

    fn handleTopic(self: *Display, msg: Message) void {
        _ = self;
        const prefix = msg.prefix orelse return;
        const channel = msg.params[0];
        if (channel.len == 0) return;
        var chb: [256]u8 = undefined;
        var nb: [256]u8 = undefined;
        event("Topic for {s} changed by {s}: {s}\n", .{ fmt.paintChannel(channel, &chb), fmt.paintNick(nickOnly(prefix), &nb), msg.trailing });
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
