const std = @import("std");
const Message = @import("message.zig").Message;
const net = std.Io.net;

const MAX_MESSAGE_LENGTH = 512;

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,

    /// The `Reader`'s internal storage. Because a single lower-level `read()`
    /// may pull in several whole IRC lines at once, this read state must be
    /// kept alive across `readMessageInto` calls. Re-creating the reader every
    /// call would discard any already-buffered but unconsumed bytes, losing
    /// messages (and eventually erroring with `EndOfStream` when the socket
    /// then reports EOF).
    read_buffer: [MAX_MESSAGE_LENGTH]u8 = undefined,
    /// Lazily instantiated on first read, once `self` lives at its final
    /// address. The `Reader` stores a slice into `read_buffer`, so building it
    /// too early (inside `init`, which returns the struct by value) would leave
    /// a dangling pointer into the moved temporary.
    reader: ?net.Stream.Reader = null,

    pub fn init(io: std.Io, host: []const u8, port: u16) !IrcClient {
        const hostname = try net.HostName.init(host);
        const stream = try hostname.connect(io, port, .{ .mode = .stream });
        return .{ .io = io, .stream = stream };
    }

    pub fn deinit(self: *IrcClient) void {
        self.stream.close(self.io);
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

        return msg;
    }
};

fn readUntilEndOfLine(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    var i: usize = 0;

    while (true) {
        if (i >= buf.len) {
            // Drain the rest of the over-long line so the stream stays in
            // sync instead of re-reading the same bytes and looping forever.
            while (true) {
                if (try reader.takeByte() == '\n') break;
            }
            return error.MessageTooLong;
        }

        const byte = try reader.takeByte();

        if (byte == '\r') {
            if (try reader.peekByte() == '\n') {
                _ = try reader.takeByte(); // consume the \n byte
            }
            return buf[0..i];
        }

        if (byte == '\n') {
            // Bare-\n line terminator; some servers do this.
            return buf[0..i];
        }

        buf[i] = byte;
        i += 1;
    }
}