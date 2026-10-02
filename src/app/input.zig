const std = @import("std");
const Lib = @import("irc-client");
const IrcClient = Lib.IrcClient;
const Display = @import("display.zig").Display;
const InputBox = @import("inputbox.zig").InputBox;

pub const Command = union(enum) {
    Join: []const u8,
    Part: struct { channel: []const u8, reason: ?[]const u8 },
    Msg: struct { target: []const u8, text: []const u8 },
    Raw: struct { command: []const u8, params: []const u8 },
    Quit: ?[]const u8,
    Help,
    List,
    Nick: []const u8,
    Topic: struct { channel: []const u8, text: ?[]const u8 },
    Names: ?[]const u8,
    Whois: []const u8,
    Who: []const u8,
    Mode: struct { target: []const u8, modes: ?[]const u8 },
    Kick: struct { channel: []const u8, nick: []const u8, reason: ?[]const u8 },
    Invite: struct { nick: []const u8, channel: []const u8 },
    Away: ?[]const u8,
    Me: struct { target: ?[]const u8, text: []const u8 },
    Unknown: []const u8,

    pub fn parse(input: []const u8, current_channel: ?[]const u8) !?Command {
        const trimmed = std.mem.trim(u8, input, " \r\n\t");
        if (trimmed.len == 0) return null;

        if (!std.mem.startsWith(u8, trimmed, "/")) {
            if (current_channel) |chan| {
                if (chan.len == 0) return error.NoCurrentChannel;
                return Command{ .Msg = .{ .target = chan, .text = trimmed } };
            }
            return error.NoCurrentChannel;
        }

        // Split "/cmd args..." into cmd and raw args (slices of `trimmed`,
        // no allocation so returned slices stay valid as long as input lives).
        const without_slash = trimmed[1..];
        const cmd_end = std.mem.indexOfScalar(u8, without_slash, ' ') orelse without_slash.len;
        const cmd = without_slash[0..cmd_end];
        var args = std.mem.trimStart(u8, without_slash[cmd_end..], " ");

        if (std.mem.eql(u8, cmd, "join") or std.mem.eql(u8, cmd, "j")) {
            const channel = nextToken(&args) orelse return error.MissingArgument;
            return Command{ .Join = channel };
        } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
            return Command{ .List = {} };
        } else if (std.mem.eql(u8, cmd, "part") or std.mem.eql(u8, cmd, "p")) {
            const channel = nextToken(&args) orelse return error.MissingArgument;
            const reason = restOrNull(&args);
            return Command{ .Part = .{ .channel = channel, .reason = reason } };
        } else if (std.mem.eql(u8, cmd, "msg") or std.mem.eql(u8, cmd, "m") or std.mem.eql(u8, cmd, "privmsg")) {
            const target = nextToken(&args) orelse return error.MissingArgument;
            const text = restOrNull(&args) orelse return error.MissingArgument;
            return Command{ .Msg = .{ .target = target, .text = text } };
        } else if (std.mem.eql(u8, cmd, "raw") or std.mem.eql(u8, cmd, "r")) {
            const command = nextToken(&args) orelse return error.MissingArgument;
            const params = restOrNull(&args) orelse "";
            return Command{ .Raw = .{ .command = command, .params = params } };
        } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
            const reason = restOrNull(&args);
            return Command{ .Quit = reason };
        } else if (std.mem.eql(u8, cmd, "nick") or std.mem.eql(u8, cmd, "n")) {
            const nick = nextToken(&args) orelse return error.MissingArgument;
            return Command{ .Nick = nick };
        } else if (std.mem.eql(u8, cmd, "topic") or std.mem.eql(u8, cmd, "t")) {
            const channel = nextToken(&args) orelse {
                if (current_channel) |chan| {
                    if (chan.len == 0) return error.MissingArgument;
                    return Command{ .Topic = .{ .channel = chan, .text = null } };
                }
                return error.MissingArgument;
            };
            const text = restOrNull(&args);
            return Command{ .Topic = .{ .channel = channel, .text = text } };
        } else if (std.mem.eql(u8, cmd, "names")) {
            const channel = nextToken(&args);
            return Command{ .Names = channel };
        } else if (std.mem.eql(u8, cmd, "whois") or std.mem.eql(u8, cmd, "w")) {
            const nick = nextToken(&args) orelse return error.MissingArgument;
            return Command{ .Whois = nick };
        } else if (std.mem.eql(u8, cmd, "who")) {
            const target = nextToken(&args) orelse {
                if (current_channel) |chan| {
                    if (chan.len == 0) return error.MissingArgument;
                    return Command{ .Who = chan };
                }
                return error.MissingArgument;
            };
            return Command{ .Who = target };
        } else if (std.mem.eql(u8, cmd, "mode")) {
            const target = nextToken(&args) orelse {
                if (current_channel) |chan| {
                    if (chan.len == 0) return error.MissingArgument;
                    return Command{ .Mode = .{ .target = chan, .modes = null } };
                }
                return error.MissingArgument;
            };
            const modes = restOrNull(&args);
            return Command{ .Mode = .{ .target = target, .modes = modes } };
        } else if (std.mem.eql(u8, cmd, "kick") or std.mem.eql(u8, cmd, "k")) {
            const channel = nextToken(&args) orelse return error.MissingArgument;
            const nick = nextToken(&args) orelse return error.MissingArgument;
            const reason = restOrNull(&args);
            return Command{ .Kick = .{ .channel = channel, .nick = nick, .reason = reason } };
        } else if (std.mem.eql(u8, cmd, "invite") or std.mem.eql(u8, cmd, "i")) {
            const nick = nextToken(&args) orelse return error.MissingArgument;
            const channel = nextToken(&args) orelse {
                if (current_channel) |chan| {
                    if (chan.len == 0) return error.MissingArgument;
                    return Command{ .Invite = .{ .nick = nick, .channel = chan } };
                }
                return error.MissingArgument;
            };
            return Command{ .Invite = .{ .nick = nick, .channel = channel } };
        } else if (std.mem.eql(u8, cmd, "away")) {
            const message = restOrNull(&args);
            return Command{ .Away = message };
        } else if (std.mem.eql(u8, cmd, "me")) {
            const text = restOrNull(&args) orelse return error.MissingArgument;
            return Command{ .Me = .{ .target = current_channel, .text = text } };
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            return Command{ .Help = {} };
        } else {
            return Command{ .Unknown = cmd };
        }
    }

    fn nextToken(args: *[]const u8) ?[]const u8 {
        args.* = std.mem.trimStart(u8, args.*, " ");
        if (args.*.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, args.*, ' ') orelse args.*.len;
        const token = args.*[0..end];
        args.* = if (end < args.*.len) args.*[end..] else args.*[end..end];
        return token;
    }

    fn restOrNull(args: *[]const u8) ?[]const u8 {
        args.* = std.mem.trim(u8, args.*, " \r\n\t");
        if (args.*.len == 0) return null;
        return args.*;
    }
};

pub fn executeCommand(client: *IrcClient, display: *Display, cmd: Command) !void {
    switch (cmd) {
        .Join => |channel| {
            try client.joinChannel(channel);
            try client.setCurrentChannel(channel);
            try display.setCurrentChannel(channel);
        },
        .Part => |p| {
            try client.partChannel(p.channel, p.reason);
            if (client.getCurrentChannel()) |current| {
                if (std.mem.eql(u8, current, p.channel)) {
                    try client.setCurrentChannel(null);
                    try display.setCurrentChannel(null);
                }
            }
        },
        .Msg => |m| {
            try client.sendMessage(m.target, m.text);
            display.echoSent(m.target, m.text, false);
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
            display.beginList();
            try client.listChannels();
            std.debug.print("Requesting channel list...\n", .{});
        },
        .Nick => |nick| {
            try client.changeNick(nick);
        },
        .Topic => |t| {
            if (t.text) |text| {
                try client.setTopic(t.channel, text);
            } else {
                try client.requestTopic(t.channel);
            }
        },
        .Names => |channel| {
            try client.requestNames(channel);
        },
        .Whois => |nick| {
            try client.whois(nick);
        },
        .Who => |target| {
            try client.who(target);
        },
        .Mode => |mo| {
            if (mo.modes) |modes| {
                try client.setMode(mo.target, modes);
            } else {
                try client.requestMode(mo.target);
            }
        },
        .Kick => |k| {
            try client.kick(k.channel, k.nick, k.reason);
        },
        .Invite => |inv| {
            try client.invite(inv.nick, inv.channel);
        },
        .Away => |message| {
            try client.away(message);
        },
        .Me => |m| {
            const target = m.target orelse {
                std.debug.print("No current channel. Use /join first.\n", .{});
                return;
            };
            if (target.len == 0) {
                std.debug.print("No current channel. Use /join first.\n", .{});
                return;
            }
            try client.sendAction(target, m.text);
            display.echoSent(target, m.text, true);
        },
        .Unknown => |unknown_cmd| {
            std.debug.print("Unknown command: /{s}. Type /help for help.\n", .{unknown_cmd});
        },
    }
}

fn printHelp() void {
    const f = @import("format.zig");
    if (f.isEnabled()) {
        std.debug.print("\n{s}{s}commands{s}\n", .{ f.bold, f.cyan, f.reset });
    } else {
        std.debug.print("\nAvailable commands:\n", .{});
    }
    std.debug.print("  /join <channel>          - Join a channel (alias: /j)\n", .{});
    std.debug.print("  /part <channel> [reason] - Leave a channel (alias: /p)\n", .{});
    std.debug.print("  /msg <target> <text>     - Send a message (alias: /m)\n", .{});
    std.debug.print("  /me <action>             - Send an action to current channel\n", .{});
    std.debug.print("  /nick <nick>             - Change nickname (alias: /n)\n", .{});
    std.debug.print("  /topic [chan] [text]     - Show or set topic (alias: /t)\n", .{});
    std.debug.print("  /names [channel]         - List users in a channel\n", .{});
    std.debug.print("  /whois <nick>            - Show info about a user (alias: /w)\n", .{});
    std.debug.print("  /who [channel]           - List users with details\n", .{});
    std.debug.print("  /mode [target] [modes]   - Show or change modes\n", .{});
    std.debug.print("  /kick <chan> <nick> [r]  - Kick a user (alias: /k)\n", .{});
    std.debug.print("  /invite <nick> [chan]    - Invite a user (alias: /i)\n", .{});
    std.debug.print("  /away [message]          - Set or clear away status\n", .{});
    std.debug.print("  /list                    - List channels (alias: /l)\n", .{});
    std.debug.print("  /raw <cmd> [params]      - Send raw IRC command (alias: /r)\n", .{});
    std.debug.print("  /quit [reason]           - Disconnect from server (alias: /q)\n", .{});
    std.debug.print("  /help                    - Show this help (alias: /h)\n", .{});
    std.debug.print("  <text>                   - Send message to current channel\n", .{});
    std.debug.print("\n", .{});
}

/// Extract the next complete line from the stdin buffer, consuming it.
/// Returns a slice of `out` without the trailing `\n`/`\r`, or null when
/// no full line is buffered yet.
fn takeLine(input_buffer: *[1024]u8, input_len: *usize, out: *[1024]u8) ?[]const u8 {
    const newline_idx = std.mem.indexOfScalar(u8, input_buffer[0..input_len.*], '\n') orelse return null;
    const clean = std.mem.trimEnd(u8, input_buffer[0..newline_idx], "\r");
    @memcpy(out[0..clean.len], clean);
    const remaining = input_len.* - (newline_idx + 1);
    std.mem.copyForwards(u8, input_buffer[0..remaining], input_buffer[newline_idx + 1 .. input_len.*]);
    input_len.* = remaining;
    return out[0..clean.len];
}

pub fn runEventLoop(client: *IrcClient, display: *Display) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const socket_fd = client.stream.socket.handle;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = socket_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var read_buffer: [512]u8 = undefined;
    var input_buffer: [1024]u8 = undefined;
    var input_len: usize = 0;

    var ibox = InputBox.init();
    defer ibox.deinit();
    if (ibox.raw) ibox.show(client.getCurrentChannel(), client.current_nick);

    while (true) {
        _ = try std.posix.poll(&poll_fds, -1);

        // Handle stdin input
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            if (ibox.raw) {
                var tmp: [256]u8 = undefined;
                const n = try std.posix.read(stdin_fd, &tmp);
                for (tmp[0..n]) |b| {
                    switch (ibox.feedByte(b)) {
                        .none => {},
                        .line => |submitted| {
                            ibox.hide();
                            if (try handleSubmittedLine(client, display, submitted)) return;
                            ibox.show(client.getCurrentChannel(), client.current_nick);
                        },
                        .interrupt => {
                            ibox.hide();
                            try client.quit(null);
                            return;
                        },
                        .eof => return,
                    }
                }
                ibox.show(client.getCurrentChannel(), client.current_nick);
            } else {
                const bytes_read = try std.posix.read(stdin_fd, input_buffer[input_len..]);
                if (bytes_read == 0) {
                    // EOF on stdin
                    break;
                }
                input_len += bytes_read;

                // Process complete lines. Each line is copied out and consumed
                // from the buffer *before* parsing, so a parse error can never
                // re-trigger on the same line (infinite error spam).
                var line_buf: [1024]u8 = undefined;
                while (takeLine(&input_buffer, &input_len, &line_buf)) |clean_line| {
                    if (try handleSubmittedLine(client, display, clean_line)) return;
                }
            }
        }

        // Drain all complete server lines, including ones already sitting in
        // the Reader's userspace buffer (poll can't see those).
        if (try client.hasCompleteLine(socket_fd)) {
            ibox.hide();
            while (try client.hasCompleteLine(socket_fd)) {
                if (try client.readMessageInto(&read_buffer)) |msg| {
                    try display.handleServerMessage(msg);
                }
            }
            ibox.show(client.getCurrentChannel(), client.current_nick);
        }

        // Handle socket errors/hangup
        if (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            ibox.hide();
            std.debug.print("Connection lost\n", .{});
            break;
        }
    }
}

/// Parse and run one submitted input line.
/// Returns true when the client should disconnect (Quit command).
fn handleSubmittedLine(client: *IrcClient, display: *Display, clean_line: []const u8) !bool {
    const cmd = Command.parse(clean_line, client.getCurrentChannel()) catch |err| {
        if (err == error.NoCurrentChannel) {
            std.debug.print("No current channel. Use /join first.\n", .{});
        } else if (err == error.MissingArgument) {
            std.debug.print("Missing argument.\n", .{});
        } else {
            std.debug.print("Parse error: {}\n", .{err});
        }
        return false;
    };

    if (cmd) |c| {
        try executeCommand(client, display, c);
        return c == .Quit;
    }
    return false;
}

test "parse nick/topic/names/whois/me commands" {
    const t = std.testing;
    const cmd_nick = (try Command.parse("/nick alice", null)).?;
    try t.expectEqualStrings("alice", cmd_nick.Nick);

    const cmd_topic_show = (try Command.parse("/topic #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_topic_show.Topic.channel);
    try t.expect(cmd_topic_show.Topic.text == null);

    const cmd_topic_set = (try Command.parse("/topic #zig hello world", null)).?;
    try t.expectEqualStrings("hello world", cmd_topic_set.Topic.text.?);

    const cmd_topic_default = (try Command.parse("/topic", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_topic_default.Topic.channel);

    const cmd_names = (try Command.parse("/names #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_names.Names.?);

    const cmd_names_none = (try Command.parse("/names", null)).?;
    try t.expect(cmd_names_none.Names == null);

    const cmd_whois = (try Command.parse("/whois alice", null)).?;
    try t.expectEqualStrings("alice", cmd_whois.Whois);

    const cmd_me = (try Command.parse("/me waves", "#zig")).?;
    try t.expectEqualStrings("waves", cmd_me.Me.text);
    try t.expectEqualStrings("#zig", cmd_me.Me.target.?);

    try t.expectError(error.MissingArgument, Command.parse("/nick", null));
    try t.expectError(error.MissingArgument, Command.parse("/whois", null));
}

test "parse who/mode/kick/invite/away commands" {
    const t = std.testing;
    const cmd_who = (try Command.parse("/who #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_who.Who);

    const cmd_who_default = (try Command.parse("/who", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_who_default.Who);

    const cmd_mode_show = (try Command.parse("/mode #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_mode_show.Mode.target);
    try t.expect(cmd_mode_show.Mode.modes == null);

    const cmd_mode_set = (try Command.parse("/mode #zig +o alice", null)).?;
    try t.expectEqualStrings("+o alice", cmd_mode_set.Mode.modes.?);

    const cmd_kick = (try Command.parse("/kick #zig bob bye now", null)).?;
    try t.expectEqualStrings("#zig", cmd_kick.Kick.channel);
    try t.expectEqualStrings("bob", cmd_kick.Kick.nick);
    try t.expectEqualStrings("bye now", cmd_kick.Kick.reason.?);

    const cmd_kick_short = (try Command.parse("/k #zig bob", null)).?;
    try t.expect(cmd_kick_short.Kick.reason == null);

    const cmd_invite = (try Command.parse("/invite bob #zig", null)).?;
    try t.expectEqualStrings("bob", cmd_invite.Invite.nick);
    try t.expectEqualStrings("#zig", cmd_invite.Invite.channel);

    const cmd_invite_default = (try Command.parse("/invite bob", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_invite_default.Invite.channel);

    const cmd_away = (try Command.parse("/away lunch break", null)).?;
    try t.expectEqualStrings("lunch break", cmd_away.Away.?);

    const cmd_back = (try Command.parse("/away", null)).?;
    try t.expect(cmd_back.Away == null);

    try t.expectError(error.MissingArgument, Command.parse("/who", null));
    try t.expectError(error.MissingArgument, Command.parse("/kick #zig", null));
    try t.expectError(error.MissingArgument, Command.parse("/invite", null));
}

test "takeLine consumes each line exactly once" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;
    const data = "hello\n/join\n";
    @memcpy(buf[0..data.len], data);
    var len: usize = data.len;

    const first = takeLine(&buf, &len, &out).?;
    try t.expectEqualStrings("hello", first);
    // The returned slice aliases `out`; copy it before the next call.
    var first_copy: [16]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);

    const second = takeLine(&buf, &len, &out).?;
    try t.expectEqualStrings("/join", second);
    try t.expectEqualStrings("hello", first_copy[0..first.len]);
    try t.expectEqual(@as(usize, 0), len);
    try t.expect(takeLine(&buf, &len, &out) == null);
}
