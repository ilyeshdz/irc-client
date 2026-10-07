const std = @import("std");
const Message = @import("../message.zig").Message;
const IrcClient = @import("mod.zig").IrcClient;
const conn = @import("conn.zig");
const MAX_MESSAGE_LENGTH = @import("mod.zig").MAX_MESSAGE_LENGTH;

/// Send a raw IRC command to the server.
pub fn send(self: *IrcClient, message: Message) !void {
    if (!self.connected) return error.NotConnected;

    // Format into a complete line first: an over-long message must never
    // reach the wire half-written, and must not be mistaken for a socket
    // failure (that would trigger a pointless reconnect). A CR/LF inside
    // any field would split one message into two on the wire, so it is
    // rejected before formatting instead.
    var line: [MAX_MESSAGE_LENGTH]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&line);
    message.format(&fixed) catch |err| {
        if (err == error.InvalidMessage) return err;
        return error.MessageTooLong;
    };

    if (self.tls_state) |state| {
        state.tls_conn.writeAll(fixed.buffered()) catch |err| {
            conn.closeStream(self); // the socket died, not the message
            return err;
        };
        // tls.zig already flushes its ciphertext per record inside
        // encryptWrite, so the bytes above reached the socket writer;
        // flush the tail explicitly in case buffering ever changes.
        state.sock_writer.interface.flush() catch |err| {
            conn.closeStream(self);
            return err;
        };
        return;
    }

    var buffer: [MAX_MESSAGE_LENGTH]u8 = undefined;
    var writer = self.stream.writer(self.io, &buffer);
    writer.interface.writeAll(fixed.buffered()) catch |err| {
        conn.closeStream(self); // the socket died, not the message
        return err;
    };
    writer.interface.flush() catch |err| {
        conn.closeStream(self);
        return err;
    };
}

/// Send a raw command with variable parameters.
pub fn sendRaw(self: *IrcClient, command: []const u8, params: []const u8) !void {
    if (command.len == 0) return error.InvalidMessage;
    // Split "a b c" into separate params so the wire form stays one line
    // with single spaces; the trailing chunk (after 14 middles) goes as
    // trailing so nothing is silently dropped.
    var middles: [14][]const u8 = .{""} ** 14;
    var n: usize = 0;
    var trailing: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, params, ' ');
    while (it.next()) |tok| {
        if (n < middles.len) {
            middles[n] = tok;
            n += 1;
        } else {
            // Everything past 14 middles becomes trailing (re-joined).
            const start = tok.ptr - params.ptr;
            trailing = std.mem.trimStart(u8, params[start..], " ");
            break;
        }
    }
    var msg = Message{ .command = command, .trailing = trailing };
    @memcpy(msg.params[0..14], middles[0..14]);
    try send(self, msg);
}
