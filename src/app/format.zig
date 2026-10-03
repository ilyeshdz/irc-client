const std = @import("std");

/// Tiny ANSI styling helpers: colors, timestamps and deterministic
/// nick colors. No fullscreen TUI, just richer line output.
/// Colors are disabled when NO_COLOR is set or stderr is not a tty.
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";

pub const cyan = "\x1b[36m";
pub const yellow = "\x1b[33m";
pub const magenta = "\x1b[35m";
pub const green = "\x1b[32m";
pub const red = "\x1b[31m";
pub const blue = "\x1b[34m";

const nick_palette = [_][]const u8{ cyan, green, yellow, magenta, blue, red };

var enabled: bool = true;
var probed: bool = false;
var clock_io: ?std.Io = null;
var clock_override: ?i64 = null;

/// Provide the Io needed for wall-clock timestamps (called once at startup).
pub fn setIo(io: std.Io) void {
    clock_io = io;
}

/// For tests: force the timestamp clock to a fixed epoch value.
pub fn setClockOverride(secs: ?i64) void {
    clock_override = secs;
}

fn probe() void {
    if (probed) return;
    probed = true;
    if (std.c.getenv("NO_COLOR") != null) {
        enabled = false;
        return;
    }
    enabled = std.c.isatty(std.posix.STDERR_FILENO) != 0;
}

pub fn isEnabled() bool {
    probe();
    return enabled;
}

/// For tests: force colors on/off.
pub fn setEnabled(v: bool) void {
    probed = true;
    enabled = v;
}

fn wrap(code: []const u8, s: []const u8, out: *[256]u8) []const u8 {
    if (!isEnabled()) return s;
    const styled = std.fmt.bufPrint(out, "{s}{s}{s}", .{ code, s, reset }) catch return s;
    return styled;
}

/// Style a nick with a deterministic color from its hash.
pub fn nickColor(nick: []const u8) []const u8 {
    var h: u32 = 0;
    for (nick) |c| h = h *% 31 +% c;
    return nick_palette[h % nick_palette.len];
}

pub fn paintNick(nick: []const u8, out: *[256]u8) []const u8 {
    return wrap(nickColor(nick), nick, out);
}

pub fn paintChannel(channel: []const u8, out: *[256]u8) []const u8 {
    return wrap(cyan ++ bold, channel, out);
}

/// Current wall-clock seconds since epoch, or null when no clock is
/// available (e.g. in tests before an Io is set).
pub fn nowSecs() ?i64 {
    if (clock_override) |o| return o;
    if (clock_io) |io| return std.Io.Timestamp.now(io, .real).toSeconds();
    return null;
}

/// "12:34:56" UTC time of day into buf (always 8 bytes + sentinel).
/// Falls back to "--:--:--" when no clock is available (e.g. in tests).
pub fn timestamp(buf: *[16]u8) []const u8 {
    const secs = nowSecs() orelse return "--:--:--";
    return timestampFromEpoch(secs, buf);
}

pub fn timestampFromEpoch(epoch_secs: i64, buf: *[16]u8) []const u8 {
    const day_secs: i64 = @mod(epoch_secs, 86400);
    const positive = if (day_secs < 0) day_secs + 86400 else day_secs;
    const h: u64 = @intCast(@divTrunc(positive, 3600));
    const m: u64 = @intCast(@divTrunc(@mod(positive, 3600), 60));
    const s: u64 = @intCast(@mod(positive, 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "??:??:??";
}

pub fn dimTimestamp(buf: *[16]u8, styled: *[32]u8) []const u8 {
    const ts = timestamp(buf);
    if (!isEnabled()) return ts;
    return std.fmt.bufPrint(styled, "{s}{s}{s}", .{ dim, ts, reset }) catch ts;
}

/// Dim-styled "HH:MM:SS" for an arbitrary epoch second — used when replaying
/// history, where each line must keep the time it was sent at.
pub fn dimTimestampAt(epoch_secs: i64, buf: *[16]u8, styled: *[32]u8) []const u8 {
    const ts = timestampFromEpoch(epoch_secs, buf);
    if (!isEnabled()) return ts;
    return std.fmt.bufPrint(styled, "{s}{s}{s}", .{ dim, ts, reset }) catch ts;
}

test "nick color is deterministic" {
    setEnabled(true);
    defer setEnabled(false);
    try std.testing.expectEqualStrings(nickColor("alice"), nickColor("alice"));
    var found_other = false;
    for (nick_palette) |c| {
        if (!std.mem.eql(u8, c, nickColor("alice"))) {
            _ = nickColor(c);
            found_other = true;
            break;
        }
    }
    try std.testing.expect(found_other);
}

test "timestamp has HH:MM:SS shape" {
    var buf: [16]u8 = undefined;
    const ts = timestampFromEpoch(45296, &buf); // 12:34:56 UTC
    try std.testing.expectEqualStrings("12:34:56", ts);
}

test "timestamp without clock falls back to placeholder" {
    setClockOverride(null);
    var buf: [16]u8 = undefined;
    // No Io set in tests, so no live clock is available.
    try std.testing.expectEqualStrings("--:--:--", timestamp(&buf));
}

test "colors off return input unchanged" {
    setEnabled(false);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("bob", paintNick("bob", &out));
}
