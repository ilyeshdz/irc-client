const std = @import("std");
const IrcClient = @import("irc-client").IrcClient;
const runEventLoop = @import("irc-client").runEventLoop;
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);

    // Use localhost if "local" arg provided, otherwise irc.ircnet.com
    const host = if (args.len > 1 and std.mem.eql(u8, args[1], "local")) "127.0.0.1" else "irc.ircnet.com";
    // Plain TCP only (no TLS), so use a 6667 port.
    var client = try IrcClient.init(io, host, 6667);
    defer client.deinit();

    try client.handshake("hdzilyes", "hdzilyes");

    try runEventLoop(&client);
}