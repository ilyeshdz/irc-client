const std = @import("std");
const out = @import("../out.zig");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");

/// Print a normal line prefixed with a dim timestamp.
pub fn line(comptime f: []const u8, args: anytype) void {
    var tsb: [16]u8 = undefined;
    var tss: [32]u8 = undefined;
    out.print("{s} ", .{fmt.dimTimestamp(&tsb, &tss)});
    out.print(f, args);
}

/// Print a channel event (join/part/quit/...) with a dim glyph prefix.
pub fn event(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        out.print("{s} {s}*{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.dim, fmt.reset });
        out.print(f, args);
    } else {
        line("* " ++ f, args);
    }
}

pub fn errLine(comptime f: []const u8, args: anytype) void {
    if (fmt.isEnabled()) {
        var tsb: [16]u8 = undefined;
        var tss: [32]u8 = undefined;
        out.print("{s} {s}✗{s} ", .{ fmt.dimTimestamp(&tsb, &tss), fmt.red, fmt.reset });
        out.print(f, args);
    } else {
        line("error: " ++ f, args);
    }
}

/// Green ✓ status line when colors are on, plain timestamped line otherwise.
pub fn statusLine(
    comptime colored_fmt: []const u8,
    colored_args: anytype,
    comptime plain_fmt: []const u8,
    plain_args: anytype,
) void {
    if (fmt.isEnabled()) {
        out.print(colored_fmt, colored_args);
    } else {
        line(plain_fmt, plain_args);
    }
}

pub fn nickOnly(prefix: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, prefix, '!');
    return it.next() orelse prefix;
}

/// Reason text for commands like KICK/PART/QUIT/TOPIC: servers may send a
/// single-word reason *without* the ':' prefix, in which case the parser
/// leaves it in params[idx] instead of trailing.
pub fn reasonOf(msg: Message, idx: usize) []const u8 {
    if (msg.trailing.len > 0) return msg.trailing;
    if (idx < msg.params.len) return msg.params[idx];
    return "";
}

pub fn isChannelTarget(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "#") or std.mem.startsWith(u8, target, "&");
}

/// Join space-separated params (skipping empties) for MODE display.
pub fn joinParams(params: []const []const u8, buf: *[256]u8) []const u8 {
    var len: usize = 0;
    for (params) |p| {
        if (p.len == 0) continue;
        const sep: usize = if (len > 0) 1 else 0;
        if (len + sep + p.len > buf.len) break;
        if (sep > 0) {
            buf[len] = ' ';
            len += 1;
        }
        @memcpy(buf[len .. len + p.len], p);
        len += p.len;
    }
    return buf[0..len];
}

pub fn parseAction(trailing: []const u8) ?[]const u8 {
    // CTCP ACTION is wrapped in \x01...\x01
    if (trailing.len < 9) return null;
    if (trailing[0] != 0x01 or trailing[trailing.len - 1] != 0x01) return null;
    const inner = trailing[1 .. trailing.len - 1];
    const prefix = "ACTION ";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    return inner[prefix.len..];
}

test "colon-less single-word reasons fall back to params" {
    // Servers may send `KICK #c nick bye` without ':'; the parser then
    // leaves "bye" in params[2] instead of trailing.
    const parsed = try Message.parse(":op!u@h KICK #zig bob bye");
    try std.testing.expectEqualStrings("", parsed.trailing);
    try std.testing.expectEqualStrings("bye", reasonOf(parsed, 2));

    const quit = try Message.parse(":bob!u@h QUIT leaving");
    try std.testing.expectEqualStrings("leaving", reasonOf(quit, 0));

    const part = try Message.parse(":bob!u@h PART #zig ciao");
    try std.testing.expectEqualStrings("ciao", reasonOf(part, 1));
}
