const std = @import("std");
const Message = @import("message.zig").Message;

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
    }

    pub fn setCurrentChannel(self: *Display, channel: ?[]const u8) void {
        self.current_channel = channel;
    }

    pub fn setCurrentNick(self: *Display, nick: []const u8) void {
        self.current_nick = nick;
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
        } else if (isCmd(msg, "332")) {
            self.handleTopicReply(msg);
        } else if (isCmd(msg, "001")) {
            std.debug.print("Connected: {s}\n", .{msg.trailing});
        } else if (isCmd(msg, "002")) {
            std.debug.print("  Host: {s}\n", .{msg.trailing});
        } else if (isCmd(msg, "003")) {
            std.debug.print("  Created: {s}\n", .{msg.trailing});
        } else if (isCmd(msg, "004")) {
            if (msg.params[0].len > 0) std.debug.print("  Server: {s}\n", .{msg.params[0]});
        } else if (isCmd(msg, "433")) {
            if (msg.params[1].len > 0) std.debug.print("Nickname {s} is already in use\n", .{msg.params[1]});
        } else if (isCmd(msg, "461")) {
            if (msg.params[1].len > 0) std.debug.print("{s}: not enough parameters\n", .{msg.params[1]});
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
        std.debug.print("\n--- MOTD ---\n", .{});
        if (motd.len > 0) {
            std.debug.print("{s}\n", .{motd});
        } else {
            std.debug.print("(empty)\n", .{});
        }
        std.debug.print("------------\n\n", .{});
    }

    // --- LIST (321/322/323) ---

    fn handleListStart(self: *Display) void {
        self.in_channel_list = true;
        std.debug.print("\n--- Channels ---\n", .{});
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
        std.debug.print("{s} [{s}] {s}\n", .{ channel, users, topic });
    }

    fn handleListEnd(self: *Display) void {
        if (self.in_channel_list) {
            self.in_channel_list = false;
            std.debug.print("------------------\n\n", .{});
        } else if (self.list_refused) {
            std.debug.print("Channel listing refused by the server (LIST is restricted here)\n\n", .{});
        } else if (self.list_count == 0) {
            std.debug.print("No channels found\n\n", .{});
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
        std.debug.print("Users in {s}: {s}\n", .{ msg.params[2], msg.trailing });
    }

    fn handleEndOfNames(_: *Display, msg: Message) void {
        if (msg.params[1].len == 0) return;
        std.debug.print("End of /names for {s}\n", .{msg.params[1]});
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
                std.debug.print("You joined {s}\n", .{channel});
                self.current_channel = channel;
            } else {
                std.debug.print("{s} joined {s}\n", .{ nick, channel });
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
                std.debug.print("You left {s}\n", .{channel});
                if (self.current_channel) |current| {
                    if (std.mem.eql(u8, current, channel)) self.current_channel = null;
                }
            } else if (msg.trailing.len > 0) {
                std.debug.print("{s} left {s} ({s})\n", .{ nick, channel, msg.trailing });
            } else {
                std.debug.print("{s} left {s}\n", .{ nick, channel });
            }
        }
    }

    fn handleQuit(_: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        if (msg.trailing.len > 0) {
            std.debug.print("{s} quit ({s})\n", .{ nick, msg.trailing });
        } else {
            std.debug.print("{s} quit\n", .{nick});
        }
    }

    fn handleNick(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const old_nick = nickOnly(prefix);
        const new_nick = msg.params[0];
        if (new_nick.len == 0) return;

        if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, old_nick, my_nick)) {
                std.debug.print("You are now known as {s}\n", .{new_nick});
                self.current_nick = new_nick;
            } else {
                std.debug.print("{s} is now known as {s}\n", .{ old_nick, new_nick });
            }
        }
    }

    fn handlePrivmsg(self: *Display, msg: Message) void {
        const prefix = msg.prefix orelse return;
        const nick = nickOnly(prefix);
        const target = msg.params[0];
        if (target.len == 0) return;

        if (isChannelTarget(target)) {
            std.debug.print("[{s}] <{s}> {s}\n", .{ target, nick, msg.trailing });
        } else if (self.current_nick) |my_nick| {
            if (std.mem.eql(u8, target, my_nick)) {
                std.debug.print("PM from {s}: {s}\n", .{ nick, msg.trailing });
            } else {
                std.debug.print("PM to {s}: {s}\n", .{ target, msg.trailing });
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
            if (isChannelTarget(target)) {
                std.debug.print("[{s}] -{s}- {s}\n", .{ target, nick, msg.trailing });
            } else {
                std.debug.print("-{s}- {s}\n", .{ nick, msg.trailing });
            }
        } else {
            std.debug.print("-server- {s}\n", .{msg.trailing});
        }
    }

    fn handleTopic(self: *Display, msg: Message) void {
        _ = self;
        const prefix = msg.prefix orelse return;
        const channel = msg.params[0];
        if (channel.len == 0) return;
        std.debug.print("Topic for {s} changed by {s}: {s}\n", .{ channel, nickOnly(prefix), msg.trailing });
    }

    fn handleTopicReply(_: *Display, msg: Message) void {
        // params: [nick, channel]
        if (msg.params[1].len == 0) return;
        if (msg.trailing.len > 0) {
            std.debug.print("Topic for {s}: {s}\n", .{ msg.params[1], msg.trailing });
        } else {
            std.debug.print("No topic set for {s}\n", .{msg.params[1]});
        }
    }
};

test "refused LIST reports refusal instead of empty list" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    d.setCurrentNick("tester");
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
    d.setCurrentNick("tester");
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
