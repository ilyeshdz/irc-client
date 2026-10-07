const std = @import("std");
const Message = @import("message.zig").Message;
const net = std.Io.net;
const tls = @import("tls");

const MAX_MESSAGE_LENGTH = 512;

// TLS via ianic/tls.zig (rather than std.crypto.tls): it answers server
// CertificateRequests with an empty Certificate when no client auth is
// configured, which Libera/OFTC require. std's client aborts the handshake
// instead (upstream ziglang/zig#17446).
const TlsState = struct {
    allocator: std.mem.Allocator,
    sock_reader: net.Stream.Reader,
    sock_writer: net.Stream.Writer,
    sock_read_buf: []u8,
    sock_write_buf: []u8,
    tls_conn: tls.Connection,
    tls_reader: tls.Connection.Reader,
    tls_read_buf: []u8,
    root_ca: std.crypto.Certificate.Bundle,
    have_root_ca: bool = false,

    fn destroy(self: *TlsState) void {
        // Best effort close_notify; the socket is going away regardless.
        self.tls_conn.close() catch {};
        const alloc = self.allocator;
        if (self.have_root_ca) self.root_ca.deinit(alloc);
        alloc.free(self.sock_read_buf);
        alloc.free(self.sock_write_buf);
        alloc.free(self.tls_read_buf);
        alloc.destroy(self);
    }
};

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,
    connected: bool = false,

    // Kept for the lifetime of the client so a dropped socket can be reopened.
    host: []const u8,
    port: u16,
    tls: bool = false,
    insecure: bool = false,
    tls_state: ?*TlsState = null,
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
        // The struct now owns `host`, so deinit is the single owner from here
        // on; a second free of the same slice would be a double free.
        errdefer client.deinit();
        try client.openStream();
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
        self.closeStream();
        // `free` of an empty slice is a no-op, so no length guards are needed.
        self.allocator.free(self.host);
        self.allocator.free(self.username);
        self.allocator.free(self.realname);
        self.allocator.free(self.current_nick);
        if (self.current_channel) |c| self.allocator.free(c);
        for (self.channels.items) |c| self.allocator.free(c);
        self.channels.deinit(self.allocator);
    }

    /// Handshake with the IRC server, sending the NICK and USER commands.
    pub fn handshake(self: *IrcClient, username: []const u8, realname: []const u8) !void {
        try self.replaceOwned(&self.username, username);
        try self.replaceOwned(&self.realname, realname);
        try self.replaceOwned(&self.current_nick, username);
        try self.register();
    }

    /// Store a copy of `src` in `dest`, freeing whatever was there before.
    fn replaceOwned(self: *IrcClient, dest: *[]const u8, src: []const u8) !void {
        const owned = try self.allocator.dupe(u8, src);
        self.allocator.free(dest.*);
        dest.* = owned;
    }

    fn openStream(self: *IrcClient) !void {
        const hostname = try net.HostName.init(self.host);
        const stream = try hostname.connect(self.io, self.port, .{ .mode = .stream });
        self.stream = stream;
        self.connected = true;
        // The reader belonged to the previous socket.
        self.reader = null;
        if (self.tls) {
            errdefer {
                self.stream.close(self.io);
                self.connected = false;
            }
            try self.startTls();
        }
    }

    /// Run a TLS handshake over the already-connected TCP stream.
    /// The root bundle lives in `tls_state` for the life of the connection.
    fn startTls(self: *IrcClient) !void {
        std.debug.assert(self.tls_state == null);
        const alloc = self.allocator;
        const state = try alloc.create(TlsState);
        errdefer alloc.destroy(state);
        state.allocator = alloc;
        state.have_root_ca = false;
        // ianic asserts these sizes: full ciphertext records both ways.
        state.sock_read_buf = try alloc.alloc(u8, tls.input_buffer_len);
        errdefer alloc.free(state.sock_read_buf);
        state.sock_write_buf = try alloc.alloc(u8, tls.output_buffer_len);
        errdefer alloc.free(state.sock_write_buf);
        // Sized for a whole decrypted record so overflow never strands
        // complete lines where hasCompleteLine cannot see them.
        state.tls_read_buf = try alloc.alloc(u8, tls.input_buffer_len);
        errdefer alloc.free(state.tls_read_buf);

        state.sock_reader = self.stream.reader(self.io, state.sock_read_buf);
        state.sock_writer = self.stream.writer(self.io, state.sock_write_buf);

        if (!self.insecure) {
            state.root_ca = try tls.config.cert.fromSystem(alloc, self.io);
            state.have_root_ca = true;
        } else {
            state.root_ca = .empty;
        }
        errdefer if (state.have_root_ca) state.root_ca.deinit(alloc);

        const rng_impl: std.Random.IoSource = .{ .io = self.io };
        state.tls_conn = tls.client(
            &state.sock_reader.interface,
            &state.sock_writer.interface,
            .{
                .host = self.host,
                .root_ca = state.root_ca,
                .now = std.Io.Clock.real.now(self.io),
                .rng = rng_impl.interface(),
                .insecure_skip_verify = self.insecure,
            },
        ) catch |err| {
            // The errdefers above release the bundle, buffers and state.
            return err;
        };
        // The handshake wrote through the socket writer; the library
        // flushes per record, but make sure the tail reached the wire.
        state.sock_writer.interface.flush() catch {};
        state.tls_reader = state.tls_conn.reader(state.tls_read_buf);
        self.tls_state = state;
    }

    /// Close the socket if it is open; safe to call twice.
    fn closeStream(self: *IrcClient) void {
        if (self.tls_state) |state| {
            state.destroy();
            self.tls_state = null;
        }
        if (self.connected) self.stream.close(self.io);
        self.connected = false;
        self.reader = null;
    }

    pub fn isTls(self: *const IrcClient) bool {
        return self.tls;
    }

    pub fn isConnected(self: *const IrcClient) bool {
        return self.connected;
    }

    /// Drop the socket without touching the remembered channels, so the
    /// event loop stops polling a dead fd until a reconnect succeeds.
    pub fn disconnect(self: *IrcClient) void {
        self.closeStream();
    }

    /// The fd to hand to poll(); only meaningful while connected.
    pub fn socketFd(self: *const IrcClient) std.posix.fd_t {
        std.debug.assert(self.connected);
        return self.stream.socket.handle;
    }

    /// Reopen the connection, register again and rejoin remembered channels.
    pub fn reconnect(self: *IrcClient) !void {
        self.closeStream();
        try self.openStream();
        errdefer self.closeStream();
        try self.register();
        // Not `joinChannel`: the channels are already remembered.
        for (self.channels.items) |channel| {
            try self.send(Message{ .command = "JOIN", .params = .{channel} ++ .{""} ** 14 });
        }
    }

    /// NICK + USER for the current socket, under the current nick.
    fn register(self: *IrcClient) !void {
        const nick = if (self.current_nick.len > 0) self.current_nick else self.username;
        try self.send(Message{ .command = "NICK", .params = .{nick} ++ .{""} ** 14 });
        try self.send(Message{ .command = "USER", .params = .{ self.username, "0", "*", self.realname } ++ .{""} ** 11 });
    }

    /// Send a raw IRC command to the server.
    pub fn send(self: *IrcClient, message: Message) !void {
        if (!self.connected) return error.NotConnected;

        // Format into a complete line first: an over-long message must never
        // reach the wire half-written, and must not be mistaken for a socket
        // failure (that would trigger a pointless reconnect).
        var line: [MAX_MESSAGE_LENGTH]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&line);
        message.format(&fixed) catch return error.MessageTooLong;

        if (self.tls_state) |state| {
            state.tls_conn.writeAll(fixed.buffered()) catch |err| {
                self.closeStream(); // the socket died, not the message
                return err;
            };
            return;
        }

        var buffer: [MAX_MESSAGE_LENGTH]u8 = undefined;
        var writer = self.stream.writer(self.io, &buffer);
        writer.interface.writeAll(fixed.buffered()) catch |err| {
            self.closeStream(); // the socket died, not the message
            return err;
        };
        writer.interface.flush() catch |err| {
            self.closeStream();
            return err;
        };
    }

    /// Send a raw command with variable parameters.
    pub fn sendRaw(self: *IrcClient, command: []const u8, params: []const u8) !void {
        try self.send(Message{ .command = command, .params = .{params} ++ .{""} ** 14 });
    }

    /// Join a channel (remembered for reconnects).
    pub fn joinChannel(self: *IrcClient, channel: []const u8) !void {
        try self.rememberChannel(channel);
        try self.send(Message{ .command = "JOIN", .params = .{channel} ++ .{""} ** 14 });
    }

    /// Request the server's channel list.
    pub fn listChannels(self: *IrcClient) !void {
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
    }

    /// Send a message to a target (channel or user).
    pub fn sendMessage(self: *IrcClient, target: []const u8, text: []const u8) !void {
        try self.send(Message{ .command = "PRIVMSG", .params = .{target} ++ .{""} ** 14, .trailing = text });
    }

    /// Leave a channel with an optional reason.
    pub fn partChannel(self: *IrcClient, channel: []const u8, reason: ?[]const u8) !void {
        self.forgetChannel(channel);
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
            self.allocator.free(c);
            self.current_channel = null;
        }
        if (channel) |ch| {
            if (ch.len > 0) self.current_channel = try self.allocator.dupe(u8, ch);
        }
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

    /// Follow our own JOIN/PART/KICK so `channels` and `current_channel` stay
    /// right even for `/raw JOIN` or a server-side kick: what the server says
    /// we are in is what a reconnect should rejoin.
    fn syncMembership(self: *IrcClient, msg: Message) void {
        // For KICK the prefix is the kicker; the kicked nick is params[1].
        if (std.mem.eql(u8, msg.command, "KICK")) {
            if (self.isSelfNick(msg.params[1])) self.leaveChannel(msg.params[0]);
            return;
        }

        const prefix = msg.prefix orelse return;
        if (!self.isSelfNick(prefix)) return;
        const channel = msg.params[0];
        if (channel.len == 0) return;

        if (std.mem.eql(u8, msg.command, "JOIN")) {
            self.rememberChannel(channel) catch return;
            self.setCurrentChannel(channel) catch return;
        } else if (std.mem.eql(u8, msg.command, "PART")) {
            self.leaveChannel(channel);
        }
    }

    /// `nick_or_prefix` may be a bare nick or a `nick!user@host` prefix.
    fn isSelfNick(self: *const IrcClient, nick_or_prefix: []const u8) bool {
        if (self.current_nick.len == 0) return false;
        const nick = if (std.mem.indexOfScalar(u8, nick_or_prefix, '!')) |i|
            nick_or_prefix[0..i]
        else
            nick_or_prefix;
        return std.mem.eql(u8, nick, self.current_nick);
    }

    /// Forget a channel we just left; drop it as the current target too.
    fn leaveChannel(self: *IrcClient, channel: []const u8) void {
        self.forgetChannel(channel);
        if (self.getCurrentChannel()) |current| {
            if (std.mem.eql(u8, current, channel)) self.setCurrentChannel(null) catch {};
        }
    }

    fn rememberChannel(self: *IrcClient, channel: []const u8) !void {
        if (channel.len == 0) return;
        for (self.channels.items) |c| {
            if (std.mem.eql(u8, c, channel)) return;
        }
        const owned = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned);
        try self.channels.append(self.allocator, owned);
    }

    fn forgetChannel(self: *IrcClient, channel: []const u8) void {
        for (self.channels.items, 0..) |c, i| {
            if (!std.mem.eql(u8, c, channel)) continue;
            self.allocator.free(c);
            _ = self.channels.orderedRemove(i);
            return;
        }
    }

    fn ensurePlainReader(self: *IrcClient) *net.Stream.Reader {
        if (self.reader == null) {
            self.reader = self.stream.reader(self.io, &self.read_buffer);
        }
        return &self.reader.?;
    }

    fn plaintextReader(self: *IrcClient) *std.Io.Reader {
        if (self.tls_state) |state| return &state.tls_reader.interface;
        return &self.ensurePlainReader().interface;
    }

    /// Returns true if a complete server line can be read without blocking:
    /// either a full line is already buffered in the Reader, or the socket
    /// has fresh data waiting (checked with a zero-timeout poll).
    /// This avoids stalling on lines stuck in the Reader's userspace buffer
    /// while poll() sleeps on an empty kernel buffer.
    /// Returns error.NotConnected while the socket is down, so a dropped
    /// connection cannot be mistaken for a quiet one.
    pub fn hasCompleteLine(self: *IrcClient) !bool {
        if (!self.connected) return error.NotConnected;
        const r = self.plaintextReader();
        if (std.mem.indexOfScalar(u8, r.buffered(), '\n') != null) return true;
        var tmp = [_]std.posix.pollfd{
            .{ .fd = self.socketFd(), .events = std.posix.POLL.IN, .revents = 0 },
        };
        return try std.posix.poll(&tmp, 0) > 0;
    }

    pub fn readMessageInto(self: *IrcClient, buffer: []u8) !?Message {
        if (!self.connected) return error.NotConnected;
        const r = self.plaintextReader();
        const line = readUntilEndOfLine(r, buffer) catch |err| {
            // A truncated line is dropped, but the socket is still fine;
            // anything else means the connection is gone.
            if (err != error.MessageTooLong) self.closeStream();
            return err;
        };

        const msg = try Message.parse(line);

        if (std.mem.eql(u8, msg.command, "PING")) {
            const token = if (msg.trailing.len > 0) msg.trailing else msg.params[0];
            try self.send(Message{ .command = "PONG", .params = .{token} ++ .{""} ** 14 });
            return null;
        }

        // Keep the client's owned nick in sync when we change nick
        // (the display layer tracks its own copy from the same message).
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

        self.syncMembership(msg);

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

test "joined channels are remembered once and dropped on part" {
    // No socket needed: only the bookkeeping is exercised.
    var client = IrcClient.initForTest(std.testing.allocator);
    defer client.deinit();

    try client.rememberChannel("#zig");
    try client.rememberChannel("#zig");
    try client.rememberChannel("#rust");
    try std.testing.expectEqual(@as(usize, 2), client.channels.items.len);

    client.forgetChannel("#zig");
    client.forgetChannel("#zig");
    try std.testing.expectEqual(@as(usize, 1), client.channels.items.len);
    try std.testing.expectEqualStrings("#rust", client.channels.items[0]);

    try client.rememberChannel("");
    try std.testing.expectEqual(@as(usize, 1), client.channels.items.len);
}

test "our own JOIN/PART/KICK decide what a reconnect rejoins" {
    const t = std.testing;
    var client = IrcClient.initForTest(t.allocator);
    defer client.deinit();
    try client.replaceOwned(&client.current_nick, "tester");

    // Someone else joining must not touch our membership.
    client.syncMembership(try Message.parse(":alice!a@h JOIN #zig"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);

    // /raw JOIN goes through the server, not through joinChannel().
    client.syncMembership(try Message.parse(":tester!u@h JOIN #zig"));
    try t.expectEqual(@as(usize, 1), client.channels.items.len);
    try t.expectEqualStrings("#zig", client.getCurrentChannel().?);

    // Another channel joined the same way, then a server-side kick.
    client.syncMembership(try Message.parse(":tester!u@h JOIN #rust"));
    try t.expectEqual(@as(usize, 2), client.channels.items.len);
    client.syncMembership(try Message.parse(":op!o@h KICK #zig tester :bye"));
    try t.expectEqualStrings("#rust", client.getCurrentChannel().?);
    try t.expectEqual(@as(usize, 1), client.channels.items.len);

    // Our own PART forgets the channel; someone else's PART does not.
    client.syncMembership(try Message.parse(":tester!u@h PART #rust"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);
    try t.expect(client.getCurrentChannel() == null);
    client.syncMembership(try Message.parse(":alice!a@h PART #rust"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);
}
