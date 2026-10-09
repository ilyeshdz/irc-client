const std = @import("std");
const out = @import("out.zig");
const Lib = @import("irc-client");
const IrcClient = Lib.IrcClient;
const Display = @import("display.zig").Display;
const InputBox = @import("inputbox.zig").InputBox;
const queue = @import("queue.zig");
const help = @import("help.zig");

/// Re-exported so `input.Command` keeps working; the type lives in `command.zig`.
pub const Command = @import("command.zig").Command;
const InputQueue = queue.InputQueue;

/// Run one parsed command. The Outcome tells the loop what to do next, so a
/// failed send and a user quit are never confused with each other.
pub fn executeCommand(client: *IrcClient, display: *Display, cmd: Command) !Outcome {
    switch (cmd) {
        .Quit => |reason| {
            // A failed QUIT still ends the session, never a reconnect.
            client.quit(reason) catch |err| std.log.debug("quit notice failed on the way out: {s}", .{@errorName(err)});
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
            help.printHelp();
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
        const msg = client.readMessageInto(buf) catch |err| {
            // The line is consumed either way; only a dead socket stops us.
            if (!client.isConnected()) return false;
            std.log.debug("dropping server line: {s}", .{@errorName(err)});
            continue;
        };
        if (msg) |m| {
            try display.handleServerMessage(m);
            // 433 (nick taken): claim `nick_` at once, or sit unregistered in backoff.
            if (std.mem.eql(u8, m.command, "433")) {
                const alt = client.useAlternateNick() catch |err| {
                    std.log.warn("433 fallback failed: {s}", .{@errorName(err)});
                    continue;
                };
                display.setCurrentNick(alt) catch |err| std.log.warn("433 fallback sent, but display nick not updated: {s}", .{@errorName(err)});
            }
        }
    }
    redrawPrompt(ibox, client);
    return true;
}

pub fn runEventLoop(client: *IrcClient, display: *Display) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    var read_buffer: [512]u8 = undefined;
    var input_buffer: [1024]u8 = undefined;
    var input_len: usize = 0;

    // One backoff for the whole session: a flapping server keeps escalating
    // instead of restarting at 1s on every drop.
    var delay_ms = queue.first_retry_ms;
    var session_started = std.Io.Timestamp.now(client.io, .awake);

    // Null while connected; the moment of the next attempt while down.
    var retry_at: ?std.Io.Timestamp = null;
    var connection_lost = false;
    var reconnect_requested = false;
    var queued = InputQueue{};

    var ibox = InputBox.init();
    defer ibox.deinit();
    if (ibox.raw) redrawPrompt(&ibox, client);

    while (true) {
        // Drop the socket here so a dead fd can never reach poll().
        if (connection_lost or reconnect_requested) {
            ibox.hide();
            client.disconnect();
            const now = std.Io.Timestamp.now(client.io, .awake);
            if (connection_lost) {
                display.err("connection lost\n", .{});
                if (queue.ageMs(session_started, now) >= queue.stable_session_ms) {
                    delay_ms = queue.first_retry_ms;
                    retry_at = now;
                } else {
                    queue.planRetry(&retry_at, &delay_ms, now, display);
                }
            } else {
                if (client.isTls()) {
                    display.info("reconnecting to {s}:+{d} (TLS)…\n", .{ client.host, client.port });
                } else {
                    display.info("reconnecting to {s}:{d}…\n", .{ client.host, client.port });
                }
                delay_ms = queue.first_retry_ms;
                retry_at = now;
            }
            connection_lost = false;
            reconnect_requested = false;
            // No wait scheduled: the next pass prints the attempt and hides
            // the prompt again; only a real wait needs it back.
            if (queue.pollTimeoutMs(retry_at, now) != 0) redrawPrompt(&ibox, client);
            continue;
        }

        const now = std.Io.Timestamp.now(client.io, .awake);

        // A due attempt runs before poll(), so the wait and the reconnect
        // never fight over one iteration.
        if (retry_at) |at| {
            if (at.nanoseconds <= now.nanoseconds) {
                ibox.hide();
                client.reconnect() catch |err| {
                    display.err("reconnect failed: {s}\n", .{@errorName(err)});
                    queue.planRetry(&retry_at, &delay_ms, now, display);
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

        // Rebuilt every pass: a reconnect closes the old fd, and a down
        // connection has none, so only the keyboard can wake poll() early.
        const socket_fd: ?std.posix.fd_t = if (client.isConnected()) client.socketFd() else null;
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = socket_fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&poll_fds, queue.pollTimeoutMs(retry_at, now));

        // Stdin first, so a typed line and a dead socket cannot race in one pass.
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
                            client.quit(null) catch |err| std.log.debug("quit notice failed on interrupt: {s}", .{@errorName(err)});
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
                    break;
                }
                input_len += bytes_read;

                // Lines are consumed before parsing, so a parse error can never
                // re-trigger on the same line (infinite error spam).
                var line_buf: [1024]u8 = undefined;
                while (queue.takeLine(&input_buffer, &input_len, &line_buf)) |clean_line| {
                    const outcome = submitLine(client, display, clean_line, retry_at != null, &queued);
                    if (routeOutcome(outcome, &connection_lost, &reconnect_requested)) return;
                    if (connection_lost or reconnect_requested) break;
                }
            }
        }

        // Drain server lines too, including ones poll() can't see: those
        // already sitting in the Reader's userspace buffer.
        if (!connection_lost and !reconnect_requested and client.isConnected()) {
            const drained = try drainServer(client, display, &ibox, &read_buffer);
            const hung_up = poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
            connection_lost = !drained or hung_up;
        }
    }
}

const Outcome = enum {
    keep,
    quit,
    reconnect,
    lost,
};

/// Fold one Outcome into the loop's flags; true when the loop must exit.
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

/// Print why a line failed to parse. Local problems are never queued
/// behind a reconnect.
fn reportParseError(err: anyerror) void {
    if (err == error.NoCurrentChannel) {
        out.print("No current channel. Use /join first.\n", .{});
    } else if (err == error.MissingArgument) {
        out.print("Missing argument.\n", .{});
    } else {
        out.print("Parse error: {}\n", .{err});
    }
}

/// Run an already-parsed command, turning send failures into an Outcome.
fn executeParsed(client: *IrcClient, display: *Display, cmd: Command) Outcome {
    return executeCommand(client, display, cmd) catch |err| {
        // Only a dead socket drops the session; anything else is shown.
        if (!client.isConnected()) return .lost;
        if (err == error.MessageTooLong) {
            out.print("Message too long (512 byte IRC limit).\n", .{});
        } else if (err == error.InvalidMessage) {
            out.print("Message rejected: empty command or line break in text.\n", .{});
        } else {
            out.print("error: {s}\n", .{@errorName(err)});
        }
        return .keep;
    };
}

fn handleSubmittedLine(client: *IrcClient, display: *Display, clean_line: []const u8) Outcome {
    const parsed = Command.parse(clean_line, client.getCurrentChannel()) catch |err| {
        reportParseError(err);
        return .keep;
    };
    const cmd = parsed orelse return .keep;
    return executeParsed(client, display, cmd);
}

/// Run a submitted line now, or hold it while the connection is down. Down,
/// only Quit/Reconnect/Help act at once; the rest waits in `queued`.
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
        display.err("input queue is full ({d} lines); line dropped\n", .{queue.max_queued_lines});
    }
    return .keep;
}

/// Replay queued lines. A line leaves only once accepted, so a failed send
/// is retried after the next reconnect instead of being lost.
fn flushQueue(client: *IrcClient, display: *Display, queued: *InputQueue) ?Outcome {
    while (queued.peek()) |line| {
        const outcome = handleSubmittedLine(client, display, line);
        if (outcome != .keep) return outcome;
        queued.pop();
    }
    return null;
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

    try t.expectEqual(@as(u64, 2_000), queue.nextRetryDelay(queue.first_retry_ms));
    try t.expectEqual(@as(u64, 4_000), queue.nextRetryDelay(2_000));
    try t.expectEqual(@as(u64, 30_000), queue.nextRetryDelay(16_000));
    try t.expectEqual(@as(u64, 30_000), queue.nextRetryDelay(queue.max_retry_ms));
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

    try t.expectEqual(Outcome.keep, submitLine(&client, &d, "hello there", true, &q));
    try t.expectEqual(@as(usize, 1), q.len);

    // Quit and help still act at once, and never fill the queue.
    try t.expectEqual(Outcome.quit, submitLine(&client, &d, "/quit", true, &q));
    try t.expectEqual(Outcome.keep, submitLine(&client, &d, "/help", true, &q));
    try t.expectEqual(@as(usize, 1), q.len);

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
