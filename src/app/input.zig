const std = @import("std");
const out = @import("out.zig");
const Lib = @import("irc-client");
const IrcClient = Lib.IrcClient;
const Display = @import("display.zig").Display;
const InputBox = @import("inputbox.zig").InputBox;
const fmt = @import("format.zig");

pub const Command = union(enum) {
    Join: []const u8,
    Part: struct { channel: []const u8, reason: ?[]const u8 },
    Msg: struct { target: []const u8, text: []const u8 },
    Raw: struct { command: []const u8, params: []const u8 },
    Quit: ?[]const u8,
    Reconnect,
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
        } else if (std.mem.eql(u8, cmd, "reconnect")) {
            return Command{ .Reconnect = {} };
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

/// Run one parsed command. The returned Outcome tells the event loop what to
/// do next, so a send failure and a user quit are never confused with each
/// other.
pub fn executeCommand(client: *IrcClient, display: *Display, cmd: Command) !Outcome {
    switch (cmd) {
        .Quit => |reason| {
            // A failed QUIT still ends the session: it must not turn into a
            // reconnect the user just asked to avoid.
            client.quit(reason) catch {};
            return .quit;
        },
        .Reconnect => return .reconnect,
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
        .Help => {
            printHelp();
        },
        .List => {
            display.beginList();
            try client.listChannels();
            out.print("Requesting channel list...\n", .{});
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
                out.print("No current channel. Use /join first.\n", .{});
                return .keep;
            };
            if (target.len == 0) {
                out.print("No current channel. Use /join first.\n", .{});
                return .keep;
            }
            try client.sendAction(target, m.text);
            display.echoSent(target, m.text, true);
        },
        .Unknown => |unknown_cmd| {
            out.print("unknown command: /{s}. Type /help for help.\n", .{unknown_cmd});
        },
    }
    return .keep;
}

const HelpRow = struct {
    cmd: []const u8,
    args: []const u8,
    desc: []const u8,
    alias: []const u8 = "",
};

/// The /help table. Column widths are derived from these rows at comptime, so
/// entries never carry manual padding — add a row and the grid reflows.
const help_rows = [_]HelpRow{
    .{ .cmd = "/join", .args = "<channel>", .desc = "Join a channel", .alias = "(alias: /j)" },
    .{ .cmd = "/part", .args = "<channel> [reason]", .desc = "Leave a channel", .alias = "(alias: /p)" },
    .{ .cmd = "/msg", .args = "<target> <text>", .desc = "Send a message", .alias = "(alias: /m)" },
    .{ .cmd = "/me", .args = "<action>", .desc = "Send an action to current channel" },
    .{ .cmd = "/nick", .args = "<nick>", .desc = "Change nickname", .alias = "(alias: /n)" },
    .{ .cmd = "/topic", .args = "[chan] [text]", .desc = "Show or set topic", .alias = "(alias: /t)" },
    .{ .cmd = "/names", .args = "[channel]", .desc = "List users in a channel" },
    .{ .cmd = "/whois", .args = "<nick>", .desc = "Show info about a user", .alias = "(alias: /w)" },
    .{ .cmd = "/who", .args = "[channel]", .desc = "List users with details" },
    .{ .cmd = "/mode", .args = "[target] [modes]", .desc = "Show or change modes" },
    .{ .cmd = "/kick", .args = "<chan> <nick> [r]", .desc = "Kick a user", .alias = "(alias: /k)" },
    .{ .cmd = "/invite", .args = "<nick> [chan]", .desc = "Invite a user", .alias = "(alias: /i)" },
    .{ .cmd = "/away", .args = "[message]", .desc = "Set or clear away status" },
    .{ .cmd = "/list", .args = "", .desc = "List channels", .alias = "(alias: /l)" },
    .{ .cmd = "/raw", .args = "<cmd> [params]", .desc = "Send raw IRC command", .alias = "(alias: /r)" },
    .{ .cmd = "/quit", .args = "[reason]", .desc = "Disconnect from server", .alias = "(alias: /q)" },
    .{ .cmd = "/reconnect", .args = "", .desc = "Reopen the connection to the server" },
    .{ .cmd = "/help", .args = "", .desc = "Show this help", .alias = "(alias: /h)" },
    .{ .cmd = "<text>", .args = "", .desc = "Send message to current channel" },
};

fn colWidth(comptime field: []const u8) usize {
    var w: usize = 0;
    for (help_rows) |row| w = @max(w, @field(row, field).len);
    return w;
}

/// The description column only needs alignment for rows that show an alias
/// after it, so alias-less rows never get trailing spaces.
fn descWidth() usize {
    var w: usize = 0;
    for (help_rows) |row| {
        if (row.alias.len != 0) w = @max(w, row.desc.len);
    }
    return w;
}

/// Build the whole menu as one string, twice: once with color escapes and
/// once without. Colors are a runtime decision (TTY / NO_COLOR), so both
/// variants are baked at comptime and `printHelp` picks one per call.
fn generateHelp(comptime styled: bool) []const u8 {
    const head: []const u8 = if (styled) fmt.bold ++ fmt.cyan else "";
    const dim: []const u8 = if (styled) fmt.dim else "";
    const name: []const u8 = if (styled) fmt.bold ++ fmt.yellow else "";
    const rst: []const u8 = if (styled) fmt.reset else "";

    const cw = colWidth("cmd");
    const aw = colWidth("args");
    const dw = descWidth();

    var text: []const u8 = "\n" ++ head ++ "Available commands" ++ rst ++ "\n\n";
    for (help_rows) |row| {
        // Anything that is not a slash command (like `<text>`) stays neutral.
        const code: []const u8 = if (std.mem.startsWith(u8, row.cmd, "/")) name else dim;
        const tail: []const u8 = if (row.alias.len == 0)
            row.desc
        else
            fmt.pad(row.desc, dw) ++ "  " ++ dim ++ row.alias ++ rst;
        text = text ++ "  " ++ code ++ fmt.pad(row.cmd, cw) ++ rst ++ "  " ++
            dim ++ fmt.pad(row.args, aw) ++ rst ++ "  " ++ tail ++ "\n";
    }
    return text ++ "\n";
}

const help_plain = generateHelp(false);
const help_styled = generateHelp(true);

fn printHelp() void {
    out.print("{s}", .{if (fmt.isEnabled()) help_styled else help_plain});
}

/// Extract the next complete line from the stdin buffer, consuming it.
/// Returns a slice of `dst` without the trailing `\n`/`\r`, or null when
/// no full line is buffered yet.
fn takeLine(input_buffer: *[1024]u8, input_len: *usize, dst: *[1024]u8) ?[]const u8 {
    const newline_idx = std.mem.indexOfScalar(u8, input_buffer[0..input_len.*], '\n') orelse return null;
    const clean = std.mem.trimEnd(u8, input_buffer[0..newline_idx], "\r");
    @memcpy(dst[0..clean.len], clean);
    const remaining = input_len.* - (newline_idx + 1);
    std.mem.copyForwards(u8, input_buffer[0..remaining], input_buffer[newline_idx + 1 .. input_len.*]);
    input_len.* = remaining;
    return dst[0..clean.len];
}

/// Reconnect backoff: 1s, doubling up to `max_retry_ms`.
const first_retry_ms: u64 = 1_000;
const max_retry_ms: u64 = 30_000;

/// A session that survived this long is healthy: the next drop starts the
/// backoff over instead of continuing to escalate.
const stable_session_ms: i64 = 10_000;

const ns_per_ms: i96 = 1_000_000;

fn nextRetryDelay(previous_ms: u64) u64 {
    return @min(previous_ms * 2, max_retry_ms);
}

/// How long ago `since` was, in milliseconds.
fn ageMs(since: std.Io.Timestamp, now: std.Io.Timestamp) i64 {
    return since.durationTo(now).toMilliseconds();
}

/// Schedule the next attempt one backoff from `now`, double the delay for the
/// wait after that, and return the wait that was just scheduled.
fn scheduleRetry(at: *?std.Io.Timestamp, delay_ms: *u64, now: std.Io.Timestamp) u64 {
    const wait_ms = delay_ms.*;
    at.* = now.addDuration(.{ .nanoseconds = @as(i96, wait_ms) * ns_per_ms });
    delay_ms.* = nextRetryDelay(delay_ms.*);
    return wait_ms;
}

/// Schedule the next attempt and tell the user how long the wait is.
fn planRetry(at: *?std.Io.Timestamp, delay_ms: *u64, now: std.Io.Timestamp, display: *Display) void {
    const wait_ms = scheduleRetry(at, delay_ms, now);
    display.info("retrying in {d}s (Ctrl-C to cancel)\n", .{wait_ms / 1000});
}

/// Lines submitted while the connection was down, replayed once it is back.
const max_queued_lines = 8;
const InputQueue = struct {
    storage: [max_queued_lines][1024]u8 = undefined,
    lens: [max_queued_lines]usize = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *InputQueue, line: []const u8) bool {
        if (self.len == max_queued_lines or line.len > 1024) return false;
        const tail = (self.head + self.len) % max_queued_lines;
        @memcpy(self.storage[tail][0..line.len], line);
        self.lens[tail] = line.len;
        self.len += 1;
        return true;
    }

    /// The oldest line, still in the queue until `pop`.
    fn peek(self: *const InputQueue) ?[]const u8 {
        if (self.len == 0) return null;
        return self.storage[self.head][0..self.lens[self.head]];
    }

    fn pop(self: *InputQueue) void {
        if (self.len == 0) return;
        self.head = (self.head + 1) % max_queued_lines;
        self.len -= 1;
    }
};

/// Milliseconds until the next attempt, or -1 when nothing is scheduled.
fn pollTimeoutMs(retry_at: ?std.Io.Timestamp, now: std.Io.Timestamp) i32 {
    const at = retry_at orelse return -1;
    const remaining_ns = at.nanoseconds - now.nanoseconds;
    if (remaining_ns <= 0) return 0;
    // Round up, so a sub-millisecond wait cannot become a busy loop.
    const ms = @divTrunc(remaining_ns + (ns_per_ms - 1), ns_per_ms);
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

/// Redraw the input prompt with the client's current context.
fn redrawPrompt(ibox: *InputBox, client: *IrcClient) void {
    ibox.show(client.getCurrentChannel(), client.current_nick);
}

/// Drain buffered server lines, hiding the prompt around the output.
/// False when the connection dropped mid-read.
fn drainServer(client: *IrcClient, display: *Display, ibox: *InputBox, buf: *[512]u8) !bool {
    const ready = client.hasCompleteLine() catch return false;
    if (!ready) return true;

    ibox.hide();
    while (true) {
        const more = client.hasCompleteLine() catch return false;
        if (!more) break;
        const msg = client.readMessageInto(buf) catch {
            // The line is consumed either way; only a dead socket stops us.
            if (!client.isConnected()) return false;
            continue;
        };
        if (msg) |m| try display.handleServerMessage(m);
    }
    redrawPrompt(ibox, client);
    return true;
}

pub fn runEventLoop(client: *IrcClient, display: *Display) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    var read_buffer: [512]u8 = undefined;
    var input_buffer: [1024]u8 = undefined;
    var input_len: usize = 0;

    // One backoff for the whole session, and the moment the current
    // connection was established, so a flapping server keeps escalating
    // instead of restarting at 1s on every drop.
    var delay_ms = first_retry_ms;
    var session_started = std.Io.Timestamp.now(client.io, .awake);

    // Null while connected; the moment of the next attempt while it is down.
    // Everything about the wait lives here, so poll() and the reconnect
    // always agree and neither of them has to block the other.
    var retry_at: ?std.Io.Timestamp = null;
    var connection_lost = false;
    var reconnect_requested = false;
    // Typed while the connection was down; replayed once it is back.
    var queued = InputQueue{};

    var ibox = InputBox.init();
    defer ibox.deinit();
    if (ibox.raw) redrawPrompt(&ibox, client);

    while (true) {
        // Consume the flags first: the socket is dropped here, so a dead fd
        // can never reach poll(), and the next pass makes the attempt.
        if (connection_lost or reconnect_requested) {
            ibox.hide();
            client.disconnect();
            const now = std.Io.Timestamp.now(client.io, .awake);
            if (connection_lost) {
                display.err("connection lost\n", .{});
                if (ageMs(session_started, now) >= stable_session_ms) {
                    // This session was healthy: start the next attempt at once.
                    delay_ms = first_retry_ms;
                    retry_at = now;
                } else {
                    // It died right away: back off before trying again.
                    planRetry(&retry_at, &delay_ms, now, display);
                }
            } else {
                display.info("reconnecting to {s}:{d}…\n", .{ client.host, client.port });
                delay_ms = first_retry_ms;
                retry_at = now;
            }
            connection_lost = false;
            reconnect_requested = false;
            // Nothing to wait for means the next pass prints the attempt and
            // hides the prompt again; only a real wait needs it back.
            if (pollTimeoutMs(retry_at, now) != 0) redrawPrompt(&ibox, client);
            continue;
        }

        const now = std.Io.Timestamp.now(client.io, .awake);

        // A due attempt runs before poll(), so the wait and the reconnect can
        // never fight over the same iteration.
        if (retry_at) |at| {
            if (at.nanoseconds <= now.nanoseconds) {
                ibox.hide();
                client.reconnect() catch |err| {
                    display.err("reconnect failed: {s}\n", .{@errorName(err)});
                    planRetry(&retry_at, &delay_ms, now, display);
                    redrawPrompt(&ibox, client);
                    continue;
                };
                display.resetConnectionState();
                display.reconnected();
                session_started = now;
                retry_at = null;
                if (queued.len > 0) {
                    display.info("replaying {d} queued line(s)…\n", .{queued.len});
                    if (flushQueue(client, display, &queued)) |outcome| {
                        if (routeOutcome(outcome, &connection_lost, &reconnect_requested)) return;
                    }
                }
                redrawPrompt(&ibox, client);
                continue;
            }
        }

        // Rebuilt every pass: after a reconnect the old fd is closed and
        // must not be polled again. A down connection has no fd at all, so
        // the only thing that can wake poll() early is the keyboard.
        const socket_fd: ?std.posix.fd_t = if (client.isConnected()) client.socketFd() else null;
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = socket_fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&poll_fds, pollTimeoutMs(retry_at, now));

        // Stdin is handled before the socket is drained, so a typed line and
        // a dead socket cannot race inside one iteration.
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            if (ibox.raw) {
                var tmp: [256]u8 = undefined;
                const n = try std.posix.read(stdin_fd, &tmp);
                if (n == 0) return; // EOF
                for (tmp[0..n]) |b| {
                    switch (ibox.feedByte(b)) {
                        .none => {},
                        .line => |submitted| {
                            ibox.hide();
                            const outcome = submitLine(client, display, submitted, retry_at != null, &queued);
                            if (routeOutcome(outcome, &connection_lost, &reconnect_requested)) return;
                        },
                        .interrupt => {
                            ibox.hide();
                            client.quit(null) catch {};
                            return;
                        },
                        .eof => return,
                    }
                    if (connection_lost or reconnect_requested) break;
                }
                // Don't redraw a prompt we are about to hide again.
                if (!connection_lost and !reconnect_requested) redrawPrompt(&ibox, client);
            } else {
                // A full buffer must not look like EOF: read() on an empty
                // slice returns 0, which the check below takes as end of input.
                if (input_len == input_buffer.len) {
                    out.print("Input too long (1024 bytes); discarded.\n", .{});
                    input_len = 0;
                }
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
                    const outcome = submitLine(client, display, clean_line, retry_at != null, &queued);
                    if (routeOutcome(outcome, &connection_lost, &reconnect_requested)) return;
                    if (connection_lost or reconnect_requested) break;
                }
            }
        }

        // Drain all complete server lines, including ones already sitting in
        // the Reader's userspace buffer (poll can't see those).
        if (!connection_lost and !reconnect_requested and client.isConnected()) {
            const drained = try drainServer(client, display, &ibox, &read_buffer);
            const hung_up = poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
            connection_lost = !drained or hung_up;
        }
    }
}

/// What the event loop should do with the line that was just submitted.
const Outcome = enum {
    keep,
    quit,
    reconnect,
    lost,
};

/// Reflect one Outcome into the loop's flags; true when the loop must exit.
fn routeOutcome(outcome: Outcome, connection_lost: *bool, reconnect_requested: *bool) bool {
    switch (outcome) {
        .keep => return false,
        .quit => return true,
        .reconnect => {
            reconnect_requested.* = true;
            return false;
        },
        .lost => {
            connection_lost.* = true;
            return false;
        },
    }
}

/// Print why a submitted line could not be parsed. Local problems, so they
/// are never queued behind a reconnect.
fn reportParseError(err: anyerror) void {
    if (err == error.NoCurrentChannel) {
        out.print("No current channel. Use /join first.\n", .{});
    } else if (err == error.MissingArgument) {
        out.print("Missing argument.\n", .{});
    } else {
        out.print("Parse error: {}\n", .{err});
    }
}

/// Run an already-parsed command, turning a send failure into an Outcome
/// instead of an error the loop would have to unwind.
fn executeParsed(client: *IrcClient, display: *Display, cmd: Command) Outcome {
    return executeCommand(client, display, cmd) catch |err| {
        // Only a dead socket means "reconnect"; everything else is just an
        // error the user should see, not a reason to drop the session.
        if (!client.isConnected()) return .lost;
        if (err == error.MessageTooLong) {
            out.print("Message too long (512 byte IRC limit).\n", .{});
        } else {
            out.print("error: {s}\n", .{@errorName(err)});
        }
        return .keep;
    };
}

/// Parse and run one submitted input line.
fn handleSubmittedLine(client: *IrcClient, display: *Display, clean_line: []const u8) Outcome {
    const parsed = Command.parse(clean_line, client.getCurrentChannel()) catch |err| {
        reportParseError(err);
        return .keep;
    };
    const cmd = parsed orelse return .keep;
    return executeParsed(client, display, cmd);
}

/// Run a submitted line now, or hold it until the connection is back. While
/// it is down only Quit/Reconnect/Help still act at once; everything else
/// waits in `queued` and is replayed after a successful reconnect.
fn submitLine(client: *IrcClient, display: *Display, line: []const u8, down: bool, queued: *InputQueue) Outcome {
    if (!down) return handleSubmittedLine(client, display, line);

    const parsed = Command.parse(line, client.getCurrentChannel()) catch |err| {
        reportParseError(err);
        return .keep;
    };
    const cmd = parsed orelse return .keep;
    switch (cmd) {
        .Quit, .Reconnect, .Help => return executeParsed(client, display, cmd),
        else => {},
    }
    if (queued.push(line)) {
        display.info("queued ({d} waiting)\n", .{queued.len});
    } else {
        display.err("input queue is full ({d} lines); line dropped\n", .{max_queued_lines});
    }
    return .keep;
}

/// Replay lines typed while the connection was down. A line leaves the queue
/// only once it was accepted, so one whose send fails again is retried after
/// the next reconnect instead of being silently lost.
fn flushQueue(client: *IrcClient, display: *Display, queued: *InputQueue) ?Outcome {
    while (queued.peek()) |line| {
        const outcome = handleSubmittedLine(client, display, line);
        if (outcome != .keep) return outcome;
        queued.pop();
    }
    return null;
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

test "routeOutcome turns an outcome into the loop's flags" {
    const t = std.testing;
    var lost = false;
    var reconnect = false;

    try t.expect(!routeOutcome(.keep, &lost, &reconnect));
    try t.expect(!lost and !reconnect);
    try t.expect(routeOutcome(.quit, &lost, &reconnect));
    try t.expect(!routeOutcome(.reconnect, &lost, &reconnect));
    try t.expect(reconnect and !lost);
    try t.expect(!routeOutcome(.lost, &lost, &reconnect));
    try t.expect(lost);
}

test "reconnect command parses and the retry delay doubles up to its cap" {
    const t = std.testing;

    const cmd = (try Command.parse("/reconnect", "#zig")).?;
    try t.expect(cmd == .Reconnect);
    try t.expect((try Command.parse("/reconnect extra", null)).? == .Reconnect);

    try t.expectEqual(@as(u64, 2_000), nextRetryDelay(first_retry_ms));
    try t.expectEqual(@as(u64, 4_000), nextRetryDelay(2_000));
    try t.expectEqual(@as(u64, 30_000), nextRetryDelay(16_000));
    try t.expectEqual(@as(u64, 30_000), nextRetryDelay(max_retry_ms));
}

test "takeLine consumes each line exactly once" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    var dst: [1024]u8 = undefined;
    const data = "hello\n/join\n";
    @memcpy(buf[0..data.len], data);
    var len: usize = data.len;

    const first = takeLine(&buf, &len, &dst).?;
    try t.expectEqualStrings("hello", first);
    // The returned slice aliases `dst`; copy it before the next call.
    var first_copy: [16]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);

    const second = takeLine(&buf, &len, &dst).?;
    try t.expectEqualStrings("/join", second);
    try t.expectEqualStrings("hello", first_copy[0..first.len]);
    try t.expectEqual(@as(usize, 0), len);
    try t.expect(takeLine(&buf, &len, &dst) == null);
}

test "InputQueue holds lines in order, across the ring and up to its cap" {
    const t = std.testing;
    var q = InputQueue{};
    try t.expect(q.peek() == null);
    try t.expectEqual(@as(usize, 0), q.len);

    try t.expect(q.push("one"));
    try t.expect(q.push("two"));
    try t.expectEqualStrings("one", q.peek().?);
    q.pop();
    try t.expectEqualStrings("two", q.peek().?);
    q.pop();
    try t.expect(q.peek() == null);

    // Drive the head to the end of the array, then push past it: the next
    // two lines must still come back in the order they were typed.
    var i: usize = 0;
    while (i < max_queued_lines - 1) : (i += 1) try t.expect(q.push("x"));
    while (i > 0) : (i -= 1) q.pop();
    try t.expectEqual(@as(usize, 0), q.len);
    try t.expect(q.push("first"));
    try t.expect(q.push("second"));
    try t.expectEqualStrings("first", q.peek().?);
    q.pop();
    try t.expectEqualStrings("second", q.peek().?);
    q.pop();

    // A full queue refuses new lines rather than overwriting the oldest.
    i = 0;
    while (i < max_queued_lines) : (i += 1) try t.expect(q.push("line"));
    try t.expectEqual(@as(usize, max_queued_lines), q.len);
    try t.expect(!q.push("one too many"));

    // A line that cannot fit in a slot is refused even with room to spare.
    var q2 = InputQueue{};
    var too_long: [1025]u8 = undefined;
    try t.expect(!q2.push(&too_long));
    try t.expectEqual(@as(usize, 0), q2.len);
}

test "the retry is scheduled from now, doubles, and never busy-spins" {
    const t = std.testing;
    const now = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
    var at: ?std.Io.Timestamp = null;
    var delay: u64 = first_retry_ms;

    try t.expectEqual(@as(u64, 1_000), scheduleRetry(&at, &delay, now));
    try t.expectEqual(now.nanoseconds + 1_000 * ns_per_ms, at.?.nanoseconds);
    try t.expectEqual(@as(u64, 2_000), delay);

    try t.expectEqual(@as(u64, 2_000), scheduleRetry(&at, &delay, now));
    try t.expectEqual(now.nanoseconds + 2_000 * ns_per_ms, at.?.nanoseconds);
    try t.expectEqual(@as(u64, 4_000), delay);

    // Nothing scheduled: block until the keyboard or the socket says
    // otherwise. Already due: give the attempt the next pass immediately.
    try t.expectEqual(@as(i32, -1), pollTimeoutMs(null, now));
    try t.expectEqual(@as(i32, 0), pollTimeoutMs(std.Io.Timestamp.fromNanoseconds(now.nanoseconds - 1), now));

    // A wait shorter than a millisecond still costs a full millisecond, so
    // poll() can never turn into a spin.
    try t.expectEqual(@as(i32, 1), pollTimeoutMs(std.Io.Timestamp.fromNanoseconds(now.nanoseconds + 1), now));
    try t.expectEqual(@as(i32, 2), pollTimeoutMs(std.Io.Timestamp.fromNanoseconds(now.nanoseconds + 1_500_000), now));
}

test "a session older than the stability window starts the backoff over" {
    const t = std.testing;
    const start = std.Io.Timestamp.fromNanoseconds(0);
    const after = std.Io.Timestamp.fromNanoseconds(stable_session_ms * ns_per_ms);

    try t.expectEqual(stable_session_ms, ageMs(start, after));
    try t.expect(ageMs(start, std.Io.Timestamp.fromNanoseconds(1)) < stable_session_ms);
}

test "lines typed while down are queued, and only leave once accepted" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var client = IrcClient.initForTest(t.allocator);
    defer client.deinit();
    try client.setCurrentChannel("#zig");

    var q = InputQueue{};

    // Ordinary text waits for the connection instead of failing.
    try t.expectEqual(Outcome.keep, submitLine(&client, &d, "hello there", true, &q));
    try t.expectEqual(@as(usize, 1), q.len);

    // Quit and help still act at once, and never fill the queue.
    try t.expectEqual(Outcome.quit, submitLine(&client, &d, "/quit", true, &q));
    try t.expectEqual(Outcome.keep, submitLine(&client, &d, "/help", true, &q));
    try t.expectEqual(@as(usize, 1), q.len);

    // Further lines stack up behind the first.
    try t.expectEqual(Outcome.keep, submitLine(&client, &d, "/msg #zig hi", true, &q));
    try t.expectEqual(@as(usize, 2), q.len);

    // Replaying into a dead socket reports the failure and leaves the line
    // queued for the reconnect after this one.
    try t.expectEqual(Outcome.lost, flushQueue(&client, &d, &q).?);
    try t.expectEqual(@as(usize, 2), q.len);
    try t.expectEqualStrings("hello there", q.peek().?);

    // With nothing to replay there is no outcome at all.
    var empty = InputQueue{};
    try t.expect(flushQueue(&client, &d, &empty) == null);
}

test "every help row starts its columns on the same byte" {
    const t = std.testing;
    const cw = colWidth("cmd");
    const aw = colWidth("args");
    const dw = descWidth();
    const desc_at = 2 + cw + 2 + aw + 2;
    const alias_at = desc_at + dw + 2;

    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, help_plain, '\n');
    while (lines.next()) |line| {
        const is_row = std.mem.startsWith(u8, line, "  /") or
            std.mem.startsWith(u8, line, "  <");
        if (!is_row) continue;
        // The description starts right after two spaces, and nothing
        // spills into the gap before it.
        try t.expect(line.len > desc_at);
        try t.expectEqual(@as(u8, ' '), line[desc_at - 1]);
        try t.expect(line[desc_at] != ' ');
        if (std.mem.indexOf(u8, line, "(alias:")) |idx|
            try t.expectEqual(@as(usize, alias_at), idx);
        try t.expect(line.len <= 80);
        rows += 1;
    }
    try t.expectEqual(help_rows.len, rows);
}

test "the styled help is the plain grid plus color escapes" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, help_styled, "\x1b[") != null);
    try t.expect(std.mem.indexOf(u8, help_plain, "\x1b[") == null);

    const stripped = try fmt.stripAnsi(t.allocator, help_styled);
    defer t.allocator.free(stripped);
    try t.expectEqualStrings(help_plain, stripped);

    // Colors wrap every field, they never change the visible text.
    try t.expect(std.mem.indexOf(u8, help_styled, fmt.bold ++ fmt.yellow ++ "/join") != null);
    try t.expect(std.mem.indexOf(u8, help_styled, fmt.dim ++ "(alias: /j)") != null);
}
