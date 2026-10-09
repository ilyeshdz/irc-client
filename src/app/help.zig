const std = @import("std");
const out = @import("out.zig");
const fmt = @import("format.zig");

pub const HelpRow = struct {
    cmd: []const u8,
    args: []const u8,
    desc: []const u8,
    alias: []const u8 = "",
};

/// Column widths derive from these rows at comptime: add a row, the grid reflows.
pub const help_rows = [_]HelpRow{
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
    .{ .cmd = "/kick", .args = "<chan> <nick> [reason]", .desc = "Kick a user", .alias = "(alias: /k)" },
    .{ .cmd = "/invite", .args = "<nick> [chan]", .desc = "Invite a user", .alias = "(alias: /i)" },
    .{ .cmd = "/away", .args = "[message]", .desc = "Set or clear away status" },
    .{ .cmd = "/list", .args = "", .desc = "List channels", .alias = "(alias: /l)" },
    .{ .cmd = "/raw", .args = "<cmd> [params]", .desc = "Send raw IRC command", .alias = "(alias: /r)" },
    .{ .cmd = "/quit", .args = "[reason]", .desc = "Disconnect from server", .alias = "(alias: /q)" },
    .{ .cmd = "/reconnect", .args = "", .desc = "Reopen the connection to the server" },
    .{ .cmd = "/help", .args = "", .desc = "Show this help", .alias = "(alias: /h)" },
    .{ .cmd = "<text>", .args = "", .desc = "Send message to current channel" },
};

pub fn colWidth(comptime field: []const u8) usize {
    var w: usize = 0;
    for (help_rows) |row| w = @max(w, @field(row, field).len);
    return w;
}

/// Only alias rows set the description width, so alias-less rows get no padding.
pub fn descWidth() usize {
    var w: usize = 0;
    for (help_rows) |row| {
        if (row.alias.len != 0) w = @max(w, row.desc.len);
    }
    return w;
}

/// Both color variants are baked at comptime; `printHelp` picks one per call.
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

pub const help_plain = generateHelp(false);
pub const help_styled = generateHelp(true);

pub fn printHelp() void {
    out.print("{s}", .{if (fmt.isEnabled()) help_styled else help_plain});
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

    try t.expect(std.mem.indexOf(u8, help_styled, fmt.bold ++ fmt.yellow ++ "/join") != null);
    try t.expect(std.mem.indexOf(u8, help_styled, fmt.dim ++ "(alias: /j)") != null);
}
