const std = @import("std");
const IrcClient = @import("irc-client").IrcClient;
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const client = try IrcClient.init(io, "irc.ircnet.com", 6667);
    defer client.deinit();

    try client.handshake("hdzilyes", "hdzilyes");

    var read_buffer: [4096]u8 = undefined;

    while (true) {
        if (try client.readMessage(&read_buffer)) |msg| {
            std.debug.print("Message: {s}\n", .{msg});
        }
    }
}
