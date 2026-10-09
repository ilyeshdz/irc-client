const std = @import("std");
const Display = @import("display.zig").Display;

/// Extract the next complete line from the stdin buffer, consuming it.
/// Returns a slice of `dst` without the trailing `\n`/`\r`, or null when
/// no full line is buffered yet.
pub fn takeLine(input_buffer: *[1024]u8, input_len: *usize, dst: *[1024]u8) ?[]const u8 {
    const newline_idx = std.mem.indexOfScalar(u8, input_buffer[0..input_len.*], '\n') orelse return null;
    const clean = std.mem.trimEnd(u8, input_buffer[0..newline_idx], "\r");
    @memcpy(dst[0..clean.len], clean);
    const remaining = input_len.* - (newline_idx + 1);
    std.mem.copyForwards(u8, input_buffer[0..remaining], input_buffer[newline_idx + 1 .. input_len.*]);
    input_len.* = remaining;
    return dst[0..clean.len];
}

/// Reconnect backoff: 1s, doubling up to `max_retry_ms`.
pub const first_retry_ms: u64 = 1_000;
pub const max_retry_ms: u64 = 30_000;

/// A session that survived this long is healthy: the next drop starts the
/// backoff over instead of continuing to escalate.
pub const stable_session_ms: i64 = 10_000;

pub const ns_per_ms: i96 = 1_000_000;

pub fn nextRetryDelay(previous_ms: u64) u64 {
    return @min(previous_ms * 2, max_retry_ms);
}

/// How long ago `since` was, in milliseconds.
pub fn ageMs(since: std.Io.Timestamp, now: std.Io.Timestamp) i64 {
    return since.durationTo(now).toMilliseconds();
}

/// Schedule the next attempt one backoff from `now`, double the delay for the
/// wait after that, and return the wait that was just scheduled.
pub fn scheduleRetry(at: *?std.Io.Timestamp, delay_ms: *u64, now: std.Io.Timestamp) u64 {
    const wait_ms = delay_ms.*;
    at.* = now.addDuration(.{ .nanoseconds = @as(i96, wait_ms) * ns_per_ms });
    delay_ms.* = nextRetryDelay(delay_ms.*);
    return wait_ms;
}

/// Schedule the next attempt and tell the user how long the wait is.
/// The wait is jittered by +-25% so clients dropped together do not
/// retry in lockstep (thundering herd on server restart).
pub fn planRetry(at: *?std.Io.Timestamp, delay_ms: *u64, now: std.Io.Timestamp, display: *Display) void {
    const wait_ms = scheduleRetry(at, delay_ms, now);
    const jittered = std.crypto.random.intRangeAtMost(u64, wait_ms * 3 / 4, wait_ms * 5 / 4);
    at.* = now.addDuration(.{ .nanoseconds = @as(i96, jittered) * ns_per_ms });
    display.info("retrying in {d}s (Ctrl-C to cancel)\n", .{jittered / 1000});
}

/// Lines submitted while the connection was down, replayed once it is back.
pub const max_queued_lines = 8;
pub const InputQueue = struct {
    storage: [max_queued_lines][1024]u8 = undefined,
    lens: [max_queued_lines]usize = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *InputQueue, line: []const u8) bool {
        if (self.len == max_queued_lines or line.len > 1024) return false;
        const tail = (self.head + self.len) % max_queued_lines;
        @memcpy(self.storage[tail][0..line.len], line);
        self.lens[tail] = line.len;
        self.len += 1;
        return true;
    }

    /// The oldest line, still in the queue until `pop`.
    pub fn peek(self: *const InputQueue) ?[]const u8 {
        if (self.len == 0) return null;
        return self.storage[self.head][0..self.lens[self.head]];
    }

    pub fn pop(self: *InputQueue) void {
        if (self.len == 0) return;
        self.head = (self.head + 1) % max_queued_lines;
        self.len -= 1;
    }
};

/// Milliseconds until the next attempt, or -1 when nothing is scheduled.
pub fn pollTimeoutMs(retry_at: ?std.Io.Timestamp, now: std.Io.Timestamp) i32 {
    const at = retry_at orelse return -1;
    const remaining_ns = at.nanoseconds - now.nanoseconds;
    if (remaining_ns <= 0) return 0;
    // Round up, so a sub-millisecond wait cannot become a busy loop.
    const ms = @divTrunc(remaining_ns + (ns_per_ms - 1), ns_per_ms);
    return @intCast(@min(ms, std.math.maxInt(i32)));
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

test "retry delay doubles up to its cap" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 2_000), nextRetryDelay(first_retry_ms));
    try t.expectEqual(@as(u64, 4_000), nextRetryDelay(2_000));
    try t.expectEqual(@as(u64, 30_000), nextRetryDelay(16_000));
    try t.expectEqual(@as(u64, 30_000), nextRetryDelay(max_retry_ms));
}
