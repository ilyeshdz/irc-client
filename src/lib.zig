const std = @import("std");
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
        try self.send("NICK {s}", .{username});
        try self.send("USER {s} 0 * :{s}", .{ username, realname });
    }

    /// Send a raw IRC command to the server.
    pub fn send(self: IrcClient, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        var writer = self.stream.writer(self.io, &buffer);
        try writer.interface.print(fmt ++ "\r\n", args);
        try writer.interface.flush();
    }

    pub fn readMessage(self: IrcClient, buffer: []u8) !?[]const u8 {
        var reader = self.stream.reader(self.io, buffer);
        const line = try reader.interface.takeDelimiter('\n') orelse return null;

        // verify whether it's ping command or not
        if (std.mem.startsWith(u8, line, "PING")) {
            const secret = line[5..];
            try self.send("PONG {s}", .{secret});
            return null;
        }

        return line;
    }
};
