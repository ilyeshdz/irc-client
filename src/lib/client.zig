const std = @import("std");
const Message = @import("message.zig").Message;
const net = std.Io.net;

pub const IrcClient = struct {
    io: std.Io,
    stream: net.Stream,

    pub fn init(io: std.Io, host: []const u8, port: u16) !IrcClient {
        const hostname = try net.HostName.init(host);
        const stream = try hostname.connect(io, port, .{ .mode = .stream });
        return .{
            .io = io,
            .stream = stream,
        };
    }

    pub fn deinit(self: IrcClient) void {
        self.stream.close(self.io);
    }

    /// Handshake with the IRC server, sending the NICK and USER commands.
    pub fn handshake(self: IrcClient, username: []const u8, realname: []const u8) !void {
        try self.send(Message{ .command = "NICK", .params = .{username} ++ .{""} ** 14 });
        try self.send(Message{ .command = "USER", .params = .{ username, "0", "*", realname } ++ .{""} ** 11 });
    }

    /// Send a raw IRC command to the server.
    pub fn send(self: IrcClient, message: Message) !void {
        var buffer: [512]u8 = undefined;
        var writer = self.stream.writer(self.io, &buffer);
        try message.format(&writer.interface);
        try writer.interface.flush();
    }

    pub fn readMessageInto(self: IrcClient, buffer: []u8) !?Message {
        var reader = self.stream.reader(self.io, buffer);
        const line = try reader.interface.takeDelimiter('\n') orelse return null;

        const msg = try Message.parse(line);

        if (std.mem.eql(u8, msg.command, "PING")) {
            const token = if (msg.trailing.len > 0) msg.trailing else msg.params[0];
            try self.send(Message{ .command = "PONG", .params = .{token} ++ .{""} ** 14 });
            return null;
        }

        return msg;
    }
};
