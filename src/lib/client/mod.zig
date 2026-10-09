const std = @import("std");
const Message = @import("../message.zig").Message;
const net = std.Io.net;

const conn = @import("conn.zig");
const sender = @import("send.zig");
const commands = @import("commands.zig");
const state = @import("state.zig");
const read = @import("read.zig");

/// RFC 2812 line limit, CRLF included. Longer lines are dropped whole with
/// MessageTooLong, never truncated mid-line.
pub const MAX_MESSAGE_LENGTH = 512;

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,
    connected: bool = false,

    // Kept for the lifetime of the client so a dropped socket can be reopened.
    host: []const u8,
    port: u16,
    tls: bool = false,
    insecure: bool = false,
    tls_state: ?*conn.TlsState = null,
    username: []const u8 = "",
    realname: []const u8 = "",

    read_buffer: [MAX_MESSAGE_LENGTH]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    allocator: std.mem.Allocator,
    current_nick: []const u8,

    current_channel: ?[]const u8 = null,

    /// Channels to rejoin after a reconnect.
    channels: std.ArrayList([]const u8) = .empty,

    pub const ConnectOptions = struct {
        tls: bool = false,
        insecure: bool = false,
    };

    pub fn init(io: std.Io, host: []const u8, port: u16) !IrcClient {
        return initOptions(io, host, port, .{});
    }

    pub fn initOptions(io: std.Io, host: []const u8, port: u16, opts: ConnectOptions) !IrcClient {
        const allocator = std.heap.page_allocator;
        var client = IrcClient{
            .io = io,
            .stream = undefined,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .tls = opts.tls,
            .insecure = opts.insecure,
            .allocator = allocator,
            .current_nick = "",
        };
        // Struct owns `host` from here on; deinit frees it exactly once.
        errdefer client.deinit();
        try conn.openStream(&client);
        return client;
    }

    /// Tests: a client with no socket, for exercising the bookkeeping only.
    pub fn initForTest(allocator: std.mem.Allocator) IrcClient {
        return .{
            .io = undefined,
            .stream = undefined,
            .host = "",
            .port = 6667,
            .allocator = allocator,
            .current_nick = "",
        };
    }

    pub fn deinit(self: *IrcClient) void {
        conn.closeStream(self);
        // Freeing an empty slice is a no-op, so no length guards needed.
        self.allocator.free(self.host);
        self.allocator.free(self.username);
        self.allocator.free(self.realname);
        self.allocator.free(self.current_nick);
        if (self.current_channel) |c| self.allocator.free(c);
        for (self.channels.items) |c| self.allocator.free(c);
        self.channels.deinit(self.allocator);
    }

    pub fn handshake(self: *IrcClient, username: []const u8, realname: []const u8) !void {
        try self.replaceOwned(&self.username, username);
        try self.replaceOwned(&self.realname, realname);
        try self.replaceOwned(&self.current_nick, username);
        try conn.register(self);
    }

    /// Store a copy of `src` in `dest`, freeing the previous value.
    /// Public for the `client/` domain modules.
    pub fn replaceOwned(self: *IrcClient, dest: *[]const u8, src: []const u8) !void {
        const owned = try self.allocator.dupe(u8, src);
        self.allocator.free(dest.*);
        dest.* = owned;
    }

    // --- Connection (conn.zig) ---

    pub fn isTls(self: *const IrcClient) bool {
        return conn.isTls(self);
    }

    pub fn isConnected(self: *const IrcClient) bool {
        return conn.isConnected(self);
    }

    pub fn disconnect(self: *IrcClient) void {
        conn.disconnect(self);
    }

    pub fn socketFd(self: *const IrcClient) std.posix.fd_t {
        return conn.socketFd(self);
    }

    pub fn reconnect(self: *IrcClient) !void {
        return conn.reconnect(self);
    }

    // --- Sending (send.zig) ---

    pub fn send(self: *IrcClient, message: Message) !void {
        return sender.send(self, message);
    }

    pub fn sendRaw(self: *IrcClient, command: []const u8, params: []const u8) !void {
        return sender.sendRaw(self, command, params);
    }

    // --- IRC commands (commands.zig) ---

    pub fn joinChannel(self: *IrcClient, channel: []const u8) !void {
        return commands.joinChannel(self, channel);
    }

    pub fn listChannels(self: *IrcClient) !void {
        return commands.listChannels(self);
    }

    pub fn changeNick(self: *IrcClient, nick: []const u8) !void {
        return commands.changeNick(self, nick);
    }

    pub fn useAlternateNick(self: *IrcClient) ![]const u8 {
        return commands.useAlternateNick(self);
    }

    pub fn requestTopic(self: *IrcClient, channel: []const u8) !void {
        return commands.requestTopic(self, channel);
    }

    pub fn setTopic(self: *IrcClient, channel: []const u8, text: []const u8) !void {
        return commands.setTopic(self, channel, text);
    }

    pub fn requestNames(self: *IrcClient, channel: ?[]const u8) !void {
        return commands.requestNames(self, channel);
    }

    pub fn whois(self: *IrcClient, nick: []const u8) !void {
        return commands.whois(self, nick);
    }

    pub fn who(self: *IrcClient, target: []const u8) !void {
        return commands.who(self, target);
    }

    pub fn requestMode(self: *IrcClient, target: []const u8) !void {
        return commands.requestMode(self, target);
    }

    pub fn setMode(self: *IrcClient, target: []const u8, modes: []const u8) !void {
        return commands.setMode(self, target, modes);
    }

    pub fn kick(self: *IrcClient, channel: []const u8, nick: []const u8, reason: ?[]const u8) !void {
        return commands.kick(self, channel, nick, reason);
    }

    pub fn invite(self: *IrcClient, nick: []const u8, channel: []const u8) !void {
        return commands.invite(self, nick, channel);
    }

    pub fn away(self: *IrcClient, message: ?[]const u8) !void {
        return commands.away(self, message);
    }

    pub fn sendAction(self: *IrcClient, target: []const u8, text: []const u8) !void {
        return commands.sendAction(self, target, text);
    }

    pub fn sendMessage(self: *IrcClient, target: []const u8, text: []const u8) !void {
        return commands.sendMessage(self, target, text);
    }

    pub fn partChannel(self: *IrcClient, channel: []const u8, reason: ?[]const u8) !void {
        return commands.partChannel(self, channel, reason);
    }

    pub fn quit(self: *IrcClient, reason: ?[]const u8) !void {
        return commands.quit(self, reason);
    }

    // --- Membership (state.zig) ---

    pub fn setCurrentChannel(self: *IrcClient, channel: ?[]const u8) !void {
        return state.setCurrentChannel(self, channel);
    }

    pub fn getCurrentChannel(self: *IrcClient) ?[]const u8 {
        return state.getCurrentChannel(self);
    }

    // --- Reading (read.zig) ---

    pub fn hasCompleteLine(self: *IrcClient) !bool {
        return read.hasCompleteLine(self);
    }

    pub fn readMessageInto(self: *IrcClient, buffer: []u8) !?Message {
        return read.readMessageInto(self, buffer);
    }
};
