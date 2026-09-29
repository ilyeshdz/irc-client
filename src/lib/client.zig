const std = @import("std");
const Message = @import("message.zig").Message;
const net = std.Io.net;

const MAX_MESSAGE_LENGTH = 512;

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,

    read_buffer: [MAX_MESSAGE_LENGTH]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    motd_buffer: std.ArrayList(u8),
    collecting_motd: bool,
    motd_complete: bool,

    current_channel: ?[]const u8 = null,

    pub fn init(io: std.Io, host: []const u8, port: u16) !IrcClient {
        const hostname = try net.HostName.init(host);
        const stream = try hostname.connect(io, port, .{ .mode = .stream });
        const motd_buffer = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 1024);
        const client = IrcClient{
            .io = io,
            .stream = stream,
            .motd_buffer = motd_buffer,
            .collecting_motd = false,
            .motd_complete = false,
            .current_channel = null,
        };
        return client;
    }

    pub fn deinit(self: *IrcClient) void {
        self.stream.close(self.io);
        self.motd_buffer.deinit(std.heap.page_allocator);
    }

    /// Handshake with the IRC server, sending the NICK and USER commands.
    pub fn handshake(self: *IrcClient, username: []const u8, realname: []const u8) !void {
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

    /// Send a message to a target (channel or user).
    pub fn sendMessage(self: *IrcClient, target: []const u8, text: []const u8) !void {
        try self.send(Message{ .command = "PRIVMSG", .params = .{target}, .trailing = text });
    }

    /// Leave a channel with an optional reason.
    pub fn partChannel(self: *IrcClient, channel: []const u8, reason: ?[]const u8) !void {
        if (reason) |r| {
            try self.send(Message{ .command = "PART", .params = .{channel}, .trailing = r });
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
    pub fn setCurrentChannel(self: *IrcClient, channel: []const u8) void {
        self.current_channel = channel;
    }

    /// Get the current channel.
    pub fn getCurrentChannel(self: *IrcClient) ?[]const u8 {
        return self.current_channel;
    }

    /// Handle MOTD-related numeric commands (375, 372, 376).
    fn handleMOTD(self: *IrcClient, message: Message) !void {
        const allocator = std.heap.page_allocator;
        if (std.mem.eql(u8, message.command, "375")) {
            // RPL_MOTDSTART - Start of MOTD
            self.collecting_motd = true;
            self.motd_complete = false;
            self.motd_buffer.clearRetainingCapacity();
            if (message.trailing.len > 0) {
                try self.motd_buffer.appendSlice(allocator, message.trailing);
                try self.motd_buffer.appendSlice(allocator, "\n");
            }
        } else if (std.mem.eql(u8, message.command, "372")) {
            // RPL_MOTD - MOTD text line
            if (self.collecting_motd and message.trailing.len > 0) {
                try self.motd_buffer.appendSlice(allocator, message.trailing);
                try self.motd_buffer.appendSlice(allocator, "\n");
            }
        } else if (std.mem.eql(u8, message.command, "376")) {
            // RPL_ENDOFMOTD - End of MOTD
            if (self.collecting_motd) {
                self.collecting_motd = false;
                self.motd_complete = true;
                if (message.trailing.len > 0) {
                    try self.motd_buffer.appendSlice(allocator, message.trailing);
                    try self.motd_buffer.appendSlice(allocator, "\n");
                }
            }
        }
    }

    /// Returns the complete MOTD if available, empty slice otherwise.
    pub fn getMOTD(self: *IrcClient) []const u8 {
        return self.motd_buffer.items;
    }

    /// Returns true if MOTD has been fully received.
    pub fn isMOTDComplete(self: *IrcClient) bool {
        return self.motd_complete;
    }

    /// Returns true if currently collecting MOTD lines.
    pub fn isCollectingMOTD(self: *IrcClient) bool {
        return self.collecting_motd;
    }

    fn ensureReader(self: *IrcClient) *net.Stream.Reader {
        if (self.reader == null) {
            self.reader = self.stream.reader(self.io, &self.read_buffer);
        }
        return &self.reader.?;
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

        try self.handleMOTD(msg);

        return msg;
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
