const std = @import("std");
const IrcClient = @import("irc-client").IrcClient;
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Plain TCP only (no TLS), so use a 6667 port.
    var client = try IrcClient.init(io, "irc.ircnet.com", 6667);
    defer client.deinit();

    try client.handshake("hdzilyes", "hdzilyes");

    var read_buffer: [512]u8 = undefined;
    var motd_printed = false;

    while (true) {
        const msg = try client.readMessageInto(&read_buffer);

        if (msg) |m| {
            std.debug.print("Raw: {s}\n", .{m.raw});
            if (m.prefix) |prefix| {
                std.debug.print("Prefix: {s}\n", .{prefix});
            }
            std.debug.print("Command: {s}\n", .{m.command});
            std.debug.print("Trailing: {s}\n", .{m.trailing});
            for (m.params) |param| {
                if (param.len == 0) continue;
                std.debug.print("Param: {s}\n", .{param});
            }
        }

        if (!motd_printed and client.isMOTDComplete()) {
            const motd = client.getMOTD();
            if (motd.len > 0) {
                std.debug.print("\n=== MOTD ===\n{s}\n==============\n", .{motd});
            } else {
                std.debug.print("\n=== MOTD (empty) ===\n", .{});
            }
            motd_printed = true;
        }
    }
}
