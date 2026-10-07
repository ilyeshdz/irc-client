const std = @import("std");
const Message = @import("../message.zig").Message;
const net = std.Io.net;
const tls = @import("tls");
const IrcClient = @import("mod.zig").IrcClient;
const send = @import("send.zig");

// TLS via ianic/tls.zig (rather than std.crypto.tls): it answers server
// CertificateRequests with an empty Certificate when no client auth is
// configured, which Libera/OFTC require. std's client aborts the handshake
// instead (upstream ziglang/zig#17446).
pub const TlsState = struct {
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

    pub fn destroy(self: *TlsState) void {
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

pub fn openStream(self: *IrcClient) !void {
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
        try startTls(self);
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
pub fn closeStream(self: *IrcClient) void {
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
    closeStream(self);
}

/// The fd to hand to poll(); only meaningful while connected.
pub fn socketFd(self: *const IrcClient) std.posix.fd_t {
    std.debug.assert(self.connected);
    return self.stream.socket.handle;
}

/// Reopen the connection, register again and rejoin remembered channels.
pub fn reconnect(self: *IrcClient) !void {
    closeStream(self);
    try openStream(self);
    errdefer closeStream(self);
    try register(self);
    // Not `joinChannel`: the channels are already remembered.
    for (self.channels.items) |channel| {
        try send.send(self, Message{ .command = "JOIN", .params = .{channel} ++ .{""} ** 14 });
    }
}

/// NICK + USER for the current socket, under the current nick.
pub fn register(self: *IrcClient) !void {
    const nick = if (self.current_nick.len > 0) self.current_nick else self.username;
    try send.send(self, Message{ .command = "NICK", .params = .{nick} ++ .{""} ** 14 });
    try send.send(self, Message{ .command = "USER", .params = .{ self.username, "0", "*", self.realname } ++ .{""} ** 11 });
}
