const std = @import("std");
const Message = @import("../message.zig").Message;
const net = std.Io.net;
const IrcClient = @import("mod.zig").IrcClient;
const conn = @import("conn.zig");
const send = @import("send.zig");
const state = @import("state.zig");

fn ensurePlainReader(self: *IrcClient) *net.Stream.Reader {
    if (self.reader == null) {
        self.reader = self.stream.reader(self.io, &self.read_buffer);
    }
    return &self.reader.?;
}

fn plaintextReader(self: *IrcClient) *std.Io.Reader {
    if (self.tls_state) |tls_state| return &tls_state.tls_reader.interface;
    return &ensurePlainReader(self).interface;
}

/// True when a server line can be read without blocking: a full line is
/// already buffered, or poll() sees fresh socket data. Reports
/// error.NotConnected while down, so a dead socket never looks idle.
pub fn hasCompleteLine(self: *IrcClient) !bool {
    if (!self.connected) return error.NotConnected;
    const r = plaintextReader(self);
    if (std.mem.indexOfScalar(u8, r.buffered(), '\n') != null) return true;
    var tmp = [_]std.posix.pollfd{
        .{ .fd = conn.socketFd(self), .events = std.posix.POLL.IN, .revents = 0 },
    };
    return try std.posix.poll(&tmp, 0) > 0;
}

pub fn readMessageInto(self: *IrcClient, buffer: []u8) !?Message {
    if (!self.connected) return error.NotConnected;
    const r = plaintextReader(self);
    const line = readUntilEndOfLine(r, buffer) catch |err| {
        // A truncated line is dropped but the socket is still alive.
        if (err != error.MessageTooLong) conn.closeStream(self);
        return err;
    };

    const msg = try Message.parse(line);

    if (std.mem.eql(u8, msg.command, "PING")) {
        const token = if (msg.trailing.len > 0) msg.trailing else msg.params[0];
        try send.send(self, Message{ .command = "PONG", .params = .{token} ++ .{""} ** 14 });
        return null;
    }

    // Our own nick change: the display tracks its own copy from the message.
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

    state.syncMembership(self, msg);

    return msg;
}

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
