const std = @import("std");
const Message = @import("message.zig").Message;
const Display = @import("display.zig").Display;
const Format = @import("format.zig");
const net = std.Io.net;

const MAX_MESSAGE_LENGTH = 512;

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,

    read_buffer: [MAX_MESSAGE_LENGTH]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    allocator: std.mem.Allocator,
    display: Display,
    current_nick: []const u8,

    current_channel: ?[]const u8 = null,

    pub fn init(io: std.Io, host: []const u8, port: u16) !IrcClient {
        const hostname = try net.HostName.init(host);
        const stream = try hostname.connect(io, port, .{ .mode = .stream });
        const allocator = std.heap.page_allocator;
        Format.setIo(io);
        const display = try Display.init(allocator);
        const client = IrcClient{
            .io = io,
            .stream = stream,
            .allocator = allocator,
            .display = display,
            .current_nick = "",
            .current_channel = null,
        };
        return client;
    }

    pub fn deinit(self: *IrcClient) void {
        self.stream.close(self.io);
        if (self.current_nick.len > 0) self.allocator.free(self.current_nick);
        if (self.current_channel) |c| {
            if (c.len > 0) self.allocator.free(c);
        }
        self.display.deinit();
    }

    /// Handshake with the IRC server, sending the NICK and USER commands.
    pub fn handshake(self: *IrcClient, username: []const u8, realname: []const u8) !void {
        const owned_nick = try self.allocator.dupe(u8, username);
        if (self.current_nick.len > 0) self.allocator.free(self.current_nick);
        self.current_nick = owned_nick;
        try self.display.setCurrentNick(username);
        try self.send(Message{ .command = "NICK", .params = .{username} ++ .{""} ** 14 });
        try self.send(Message{ .command = "USER", .params = .{ username, "0", "*", realname } ++ .{""} ** 11 });
    }

    /// Send a raw IRC command to the server.
    pub fn send(self: *IrcClient, message: Message) !void {
        var buffer: [512]u8 = undefined;
        var writer = self.stream.writer(self.io, &buffer);
        try message.format(&writer.interface);
        try writer.interface.flush();
    }

    /// Send a raw command with variable parameters.
    pub fn sendRaw(self: *IrcClient, command: []const u8, params: []const u8) !void {
        try self.send(Message{ .command = command, .params = .{params} ++ .{""} ** 14 });
    }

    /// Join a channel.
    pub fn joinChannel(self: *IrcClient, channel: []const u8) !void {
        try self.send(Message{ .command = "JOIN", .params = .{channel} ++ .{""} ** 14 });
    }

    /// Request the server's channel list.
    pub fn listChannels(self: *IrcClient) !void {
        self.display.beginList();
        try self.sendRaw("list", "");
    }

    /// Change nickname.
    pub fn changeNick(self: *IrcClient, nick: []const u8) !void {
        try self.send(Message{ .command = "NICK", .params = .{nick} ++ .{""} ** 14 });
    }

    /// Request the topic of a channel.
    pub fn requestTopic(self: *IrcClient, channel: []const u8) !void {
        try self.send(Message{ .command = "TOPIC", .params = .{channel} ++ .{""} ** 14 });
    }

    /// Set the topic of a channel.
    pub fn setTopic(self: *IrcClient, channel: []const u8, text: []const u8) !void {
        try self.send(Message{ .command = "TOPIC", .params = .{channel} ++ .{""} ** 14, .trailing = text });
    }

    /// Request the user list of a channel (or all visible users if null).
    pub fn requestNames(self: *IrcClient, channel: ?[]const u8) !void {
        if (channel) |ch| {
            try self.send(Message{ .command = "NAMES", .params = .{ch} ++ .{""} ** 14 });
        } else {
            try self.send(Message{ .command = "NAMES" });
        }
    }

    /// Request WHOIS info about a nick.
    pub fn whois(self: *IrcClient, nick: []const u8) !void {
        try self.send(Message{ .command = "WHOIS", .params = .{nick} ++ .{""} ** 14 });
    }

    /// Request WHO info about a channel or nick mask.
    pub fn who(self: *IrcClient, target: []const u8) !void {
        try self.send(Message{ .command = "WHO", .params = .{target} ++ .{""} ** 14 });
    }

    /// Request the modes of a channel (or nick).
    pub fn requestMode(self: *IrcClient, target: []const u8) !void {
        try self.send(Message{ .command = "MODE", .params = .{target} ++ .{""} ** 14 });
    }

    /// Set modes on a target, e.g. `/mode #zig +o alice`.
    pub fn setMode(self: *IrcClient, target: []const u8, modes: []const u8) !void {
        var first: []const u8 = modes;
        var rest: []const u8 = "";
        if (std.mem.indexOfScalar(u8, modes, ' ')) |i| {
            first = modes[0..i];
            rest = std.mem.trimStart(u8, modes[i + 1 ..], " ");
        }
        if (rest.len > 0) {
            try self.send(Message{ .command = "MODE", .params = .{ target, first, rest } ++ .{""} ** 12 });
        } else {
            try self.send(Message{ .command = "MODE", .params = .{ target, first } ++ .{""} ** 13 });
        }
    }

    /// Kick a nick from a channel with an optional reason.
    pub fn kick(self: *IrcClient, channel: []const u8, nick: []const u8, reason: ?[]const u8) !void {
        if (reason) |r| {
            try self.send(Message{ .command = "KICK", .params = .{ channel, nick } ++ .{""} ** 13, .trailing = r });
        } else {
            try self.send(Message{ .command = "KICK", .params = .{ channel, nick } ++ .{""} ** 13 });
        }
    }

    /// Invite a nick to a channel.
    pub fn invite(self: *IrcClient, nick: []const u8, channel: []const u8) !void {
        try self.send(Message{ .command = "INVITE", .params = .{ nick, channel } ++ .{""} ** 13 });
    }

    /// Set yourself away (no message clears the away status).
    pub fn away(self: *IrcClient, message: ?[]const u8) !void {
        if (message) |m| {
            try self.send(Message{ .command = "AWAY", .trailing = m });
        } else {
            try self.send(Message{ .command = "AWAY" });
        }
    }

    /// Send a /me action (CTCP ACTION) to a target.
    pub fn sendAction(self: *IrcClient, target: []const u8, text: []const u8) !void {
        var buf: [512]u8 = undefined;
        const action = try std.fmt.bufPrint(&buf, "\x01ACTION {s}\x01", .{text});
        try self.send(Message{ .command = "PRIVMSG", .params = .{target} ++ .{""} ** 14, .trailing = action });
        self.display.echoSent(target, text, true);
    }

    /// Send a message to a target (channel or user).
    pub fn sendMessage(self: *IrcClient, target: []const u8, text: []const u8) !void {
        try self.send(Message{ .command = "PRIVMSG", .params = .{target} ++ .{""} ** 14, .trailing = text });
        self.display.echoSent(target, text, false);
    }

    /// Leave a channel with an optional reason.
    pub fn partChannel(self: *IrcClient, channel: []const u8, reason: ?[]const u8) !void {
        if (reason) |r| {
            try self.send(Message{ .command = "PART", .params = .{channel} ++ .{""} ** 14, .trailing = r });
        } else {
            try self.send(Message{ .command = "PART", .params = .{channel} ++ .{""} ** 14 });
        }
    }

    /// Quit the server with an optional reason.
    pub fn quit(self: *IrcClient, reason: ?[]const u8) !void {
        if (reason) |r| {
            try self.send(Message{ .command = "QUIT", .trailing = r });
        } else {
            try self.send(Message{ .command = "QUIT" });
        }
    }

    /// Set the current channel for default message targeting.
    /// Takes ownership of a copy; passing null or an empty slice clears it.
    pub fn setCurrentChannel(self: *IrcClient, channel: ?[]const u8) !void {
        if (self.current_channel) |c| {
            if (c.len > 0) self.allocator.free(c);
            self.current_channel = null;
        }
        if (channel) |ch| {
            if (ch.len > 0) self.current_channel = try self.allocator.dupe(u8, ch);
        }
        try self.display.setCurrentChannel(channel);
    }

    /// Get the current channel (null when not in a channel;
    /// never returns an empty slice).
    pub fn getCurrentChannel(self: *IrcClient) ?[]const u8 {
        if (self.current_channel) |c| {
            if (c.len == 0) return null;
            return c;
        }
        return null;
    }

    fn ensureReader(self: *IrcClient) *net.Stream.Reader {
        if (self.reader == null) {
            self.reader = self.stream.reader(self.io, &self.read_buffer);
        }
        return &self.reader.?;
    }

    /// Returns true if a complete server line can be read without blocking:
    /// either a full line is already buffered in the Reader, or the socket
    /// has fresh data waiting (checked with a zero-timeout poll).
    /// This avoids stalling on lines stuck in the Reader's userspace buffer
    /// while poll() sleeps on an empty kernel buffer.
    pub fn hasCompleteLine(self: *IrcClient, socket_fd: std.posix.fd_t) !bool {
        const r = self.ensureReader();
        if (std.mem.indexOfScalar(u8, r.interface.buffered(), '\n') != null) return true;
        var tmp = [_]std.posix.pollfd{
            .{ .fd = socket_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        return try std.posix.poll(&tmp, 0) > 0;
    }

    pub fn readMessageInto(self: *IrcClient, buffer: []u8) !?Message {
        const r = self.ensureReader();
        const line = try readUntilEndOfLine(&r.interface, buffer);

        const msg = try Message.parse(line);

        if (std.mem.eql(u8, msg.command, "PING")) {
            const token = if (msg.trailing.len > 0) msg.trailing else msg.params[0];
            try self.send(Message{ .command = "PONG", .params = .{token} ++ .{""} ** 14 });
            return null;
        }

        try self.display.handleServerMessage(msg);

        // Keep the client's owned nick in sync when we change nick
        // (Display only tracks its own copy).
        if (std.mem.eql(u8, msg.command, "NICK")) {
            if (msg.prefix) |prefix| {
                const excl = std.mem.indexOfScalar(u8, prefix, '!') orelse prefix.len;
                const old_nick = prefix[0..excl];
                if (std.mem.eql(u8, old_nick, self.current_nick) and msg.params[0].len > 0) {
                    const owned = try self.allocator.dupe(u8, msg.params[0]);
                    self.allocator.free(self.current_nick);
                    self.current_nick = owned;
                }
            }
        }

        return msg;
    }

    pub fn isMOTDComplete(self: *IrcClient) bool {
        return self.display.isMOTDComplete();
    }
};

fn readUntilEndOfLine(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    var i: usize = 0;

    while (true) {
        if (i >= buf.len) {
            while (true) {
                if (try reader.takeByte() == '\n') break;
            }
            return error.MessageTooLong;
        }

        const byte = try reader.takeByte();

        if (byte == '\r') {
            if (try reader.peekByte() == '\n') {
                _ = try reader.takeByte();
            }
            return buf[0..i];
        }

        if (byte == '\n') {
            return buf[0..i];
        }

        buf[i] = byte;
        i += 1;
    }
}
