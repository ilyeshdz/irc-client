const std = @import("std");
const IrcClient = @import("client.zig").IrcClient;

pub const Command = union(enum) {
    Join: []const u8,
    Part: struct { channel: []const u8, reason: ?[]const u8 },
    Msg: struct { target: []const u8, text: []const u8 },
    Raw: struct { command: []const u8, params: []const u8 },
    Quit: ?[]const u8,
    Help,
    List,
    Unknown: []const u8,

    pub fn parse(input: []const u8, current_channel: ?[]const u8) !?Command {
        const trimmed = std.mem.trim(u8, input, " \r\n\t");
        if (trimmed.len == 0) return null;

        if (!std.mem.startsWith(u8, trimmed, "/")) {
            if (current_channel) |chan| {
                return Command{ .Msg = .{ .target = chan, .text = trimmed } };
            }
            return error.NoCurrentChannel;
        }

        var iter = std.mem.splitScalar(u8, trimmed[1..], ' ');
        const cmd = iter.next() orelse return error.EmptyInput;

        if (std.mem.eql(u8, cmd, "join") or std.mem.eql(u8, cmd, "j")) {
            const channel = iter.next() orelse return error.MissingArgument;
            return Command{ .Join = channel };
        } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
            return Command{ .List = {} };
        } else if (std.mem.eql(u8, cmd, "part") or std.mem.eql(u8, cmd, "p")) {
            const channel = iter.next() orelse return error.MissingArgument;
            var reason: ?[]const u8 = null;
            if (iter.next()) |r| {
                reason = r;
                while (iter.next()) |_| {}
            }
            return Command{ .Part = .{ .channel = channel, .reason = reason } };
        } else if (std.mem.eql(u8, cmd, "msg") or std.mem.eql(u8, cmd, "m") or std.mem.eql(u8, cmd, "privmsg")) {
            const target = iter.next() orelse return error.MissingArgument;
            const text = iter.next() orelse return error.MissingArgument;
            var rest = text;
            while (iter.next()) |r| {
                rest = try std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ rest, r });
                defer std.heap.page_allocator.free(rest);
            }
            return Command{ .Msg = .{ .target = target, .text = rest } };
        } else if (std.mem.eql(u8, cmd, "raw") or std.mem.eql(u8, cmd, "r")) {
            const command = iter.next() orelse return error.MissingArgument;
            var params: []const u8 = "";
            if (iter.next()) |p| {
                params = p;
                while (iter.next()) |r| {
                    params = try std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ params, r });
                    defer std.heap.page_allocator.free(params);
                }
            }
            return Command{ .Raw = .{ .command = command, .params = params } };
        } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
            var reason: ?[]const u8 = null;
            if (iter.next()) |r| {
                reason = r;
                while (iter.next()) |_| {}
            }
            return Command{ .Quit = reason };
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            return Command{ .Help = {} };
        } else {
            return Command{ .Unknown = cmd };
        }
    }
};

pub fn executeCommand(client: *IrcClient, cmd: Command) !void {
    switch (cmd) {
        .Join => |channel| {
            try client.joinChannel(channel);
            client.setCurrentChannel(channel);
        },
        .Part => |p| {
            try client.partChannel(p.channel, p.reason);
            if (client.getCurrentChannel()) |current| {
                if (std.mem.eql(u8, current, p.channel)) {
                    client.setCurrentChannel("");
                }
            }
        },
        .Msg => |m| {
            try client.sendMessage(m.target, m.text);
        },
        .Raw => |r| {
            try client.sendRaw(r.command, r.params);
        },
        .Quit => |reason| {
            try client.quit(reason);
        },
        .Help => {
            printHelp();
        },
        .List => {
            try client.listChannels();
            std.debug.print("Requesting channel list...\n", .{});
        },
        .Unknown => |unknown_cmd| {
            std.debug.print("Unknown command: /{s}. Type /help for help.\n", .{unknown_cmd});
        },
    }
}

fn printHelp() void {
    std.debug.print("\nAvailable commands:\n", .{});
    std.debug.print("  /join <channel>     - Join a channel (alias: /j)\n", .{});
    std.debug.print("  /part [channel] [reason] - Leave a channel (alias: /p)\n", .{});
    std.debug.print("  /msg <target> <text> - Send a message (alias: /m)\n", .{});
    std.debug.print("  /list               - List channels (alias: /l)\n", .{});
    std.debug.print("  /raw <cmd> [params] - Send raw IRC command (alias: /r)\n", .{});
    std.debug.print("  /quit [reason]      - Disconnect from server (alias: /q)\n", .{});
    std.debug.print("  /help               - Show this help (alias: /h)\n", .{});
    std.debug.print("  <text>              - Send message to current channel\n", .{});
    std.debug.print("\n", .{});
}

pub fn runEventLoop(client: *IrcClient) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const socket_fd = client.stream.socket.handle;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = socket_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var read_buffer: [512]u8 = undefined;
    var input_buffer: [1024]u8 = undefined;
    var input_len: usize = 0;

    while (true) {
        _ = try std.posix.poll(&poll_fds, -1);

        // Handle stdin input
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try std.posix.read(stdin_fd, input_buffer[input_len..]);
            if (bytes_read == 0) {
                // EOF on stdin
                break;
            }
            input_len += bytes_read;

            // Process complete lines
            while (true) {
                if (std.mem.indexOfScalar(u8, input_buffer[0..input_len], '\n')) |newline_idx| {
                    const line = input_buffer[0..newline_idx];
                    // Remove trailing \r if present
                    const clean_line = std.mem.trimEnd(u8, line, "\r");

                    const cmd = Command.parse(clean_line, client.getCurrentChannel()) catch |err| {
                        switch (err) {
                            error.NoCurrentChannel => std.debug.print("No current channel. Use /join first.\n", .{}),
                            error.MissingArgument => std.debug.print("Missing argument.\n", .{}),
                            else => std.debug.print("Parse error: {}\n", .{err}),
                        }
                        continue;
                    };

                    if (cmd) |c| {
                        if (c == .Quit) {
                            try executeCommand(client, c);
                            return;
                        }
                        try executeCommand(client, c);
                    }

                    // Shift remaining buffer
                    const remaining = input_len - (newline_idx + 1);
                    std.mem.copyForwards(u8, input_buffer[0..remaining], input_buffer[newline_idx + 1 .. input_len]);
                    input_len = remaining;
                } else {
                    break;
                }
            }
        }

        // Drain all complete server lines, including ones already sitting in
        // the Reader's userspace buffer (poll can't see those).
        while (try client.hasCompleteLine(socket_fd)) {
            _ = try client.readMessageInto(&read_buffer);
        }

        // Handle socket errors/hangup
        if (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            std.debug.print("Connection lost\n", .{});
            break;
        }
    }
}
