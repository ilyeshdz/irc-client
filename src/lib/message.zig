const std = @import("std");

/// The maximum amount of params we can allocate to the memory
const MAX_PARAMS = 15;

pub const Message = struct {
    prefix: ?[]const u8 = null,
    command: []const u8 = "",
    params: [MAX_PARAMS][]const u8 = .{""} ** MAX_PARAMS,
    trailing: []const u8 = "",
    /// Raw IRCv3 tags (`@time=...;+draft/...`), without the leading `@`.
    /// Parsed and skipped so tagged lines don't shift the command; the
    /// client does not negotiate CAPs yet, so tags carry no semantics here.
    tags: ?[]const u8 = null,

    /// Parses a message from a plain string into a `Message` struct.
    /// Fails with `error.InvalidMessage` on empty lines, prefix-only lines
    /// (`:nick` with no command) and missing commands, instead of returning
    /// a silent empty struct.
    pub fn parse(line_in: []const u8) !Message {
        var msg: Message = .{};
        // IRC lines end with CRLF; strip any trailing \r / \n so they don't
        // leak into the trailing parameter.
        const line = std.mem.trimEnd(u8, line_in, "\r\n");
        if (line.len == 0) return error.InvalidMessage;
        var cursor: usize = 0;

        // IRCv3 tags precede everything: `@a=b;c=d :prefix CMD ...`.
        // No spaces inside the tag section, so the first space ends it.
        if (line[cursor] == '@') {
            const space_idx = std.mem.findScalarPos(u8, line, 0, ' ') orelse return error.InvalidMessage;
            msg.tags = line[1..space_idx];
            cursor = space_idx + 1;
            while (cursor < line.len and line[cursor] == ' ') : (cursor += 1) {}
            if (cursor >= line.len) return error.InvalidMessage;
        }

        if (std.mem.startsWith(u8, line[cursor..], ":")) {
            if (std.mem.findScalarPos(u8, line, cursor, ' ')) |space_idx| {
                msg.prefix = line[cursor + 1 .. space_idx];
                cursor = space_idx + 1;
            } else {
                return error.InvalidMessage;
            }
        }

        // Skip any extra spaces between prefix and command
        while (cursor < line.len and line[cursor] == ' ') : (cursor += 1) {}
        if (cursor >= line.len) return error.InvalidMessage;

        if (cursor < line.len) {
            if (std.mem.indexOfScalarPos(u8, line, cursor, ' ')) |space_idx| {
                msg.command = line[cursor..space_idx];
                cursor = space_idx + 1;
            } else {
                msg.command = line[cursor..];
                cursor = line.len;
            }
        }

        var params: [MAX_PARAMS][]const u8 = .{""} ** MAX_PARAMS; // allocate and fill that allocated space with [1]const u8
        var params_len: usize = 0;

        var params_slice: []const u8 = undefined;
        if (cursor < line.len and line[cursor] == ':') {
            // Trailing starts immediately after the command, e.g. `PING :server`.
            msg.trailing = line[cursor + 1 ..];
            params_slice = "";
        } else if (std.mem.indexOf(u8, line[cursor..], " :")) |colon_offset| {
            const trailing_start = cursor + colon_offset + 2;
            msg.trailing = line[trailing_start..];
            params_slice = line[cursor .. cursor + colon_offset];
        } else {
            params_slice = line[cursor..];
        }

        var it = std.mem.tokenizeScalar(u8, params_slice, ' ');
        while (it.next()) |param| {
            if (params_len >= params.len) break;
            params[params_len] = param;
            params_len += 1;
        }
        msg.params = params;

        return msg;
    }

    /// Formats the message into a full IRC line, terminated by CRLF.
    pub fn format(self: Message, writer: *std.Io.Writer) !void {
        if (self.command.len == 0) return error.InvalidMessage;
        if (hasCrlf(self.command)) return error.InvalidMessage;
        if (self.prefix) |prefix| {
            if (hasCrlf(prefix)) return error.InvalidMessage;
            try writer.writeAll(":");
            try writer.writeAll(prefix);
            try writer.writeAll(" ");
        }
        try writer.writeAll(self.command);
        for (self.params) |param| {
            if (param.len == 0) continue;
            if (hasCrlf(param)) return error.InvalidMessage;
            try writer.writeAll(" ");
            try writer.writeAll(param);
        }
        if (self.trailing.len > 0) {
            if (hasCrlf(self.trailing)) return error.InvalidMessage;
            try writer.writeAll(" :");
            try writer.writeAll(self.trailing);
        }
        try writer.writeAll("\r\n");
    }

    fn hasCrlf(s: []const u8) bool {
        return std.mem.indexOfScalar(u8, s, '\r') != null or
            std.mem.indexOfScalar(u8, s, '\n') != null;
    }
};

test "parse PRIVMSG with prefix and trailing" {
    const t = std.testing;
    const m = try Message.parse(":alice!u@h PRIVMSG #zig :hello there\r\n");
    try t.expectEqualStrings("alice!u@h", m.prefix.?);
    try t.expectEqualStrings("PRIVMSG", m.command);
    try t.expectEqualStrings("#zig", m.params[0]);
    try t.expectEqualStrings("hello there", m.trailing);
    try t.expect(m.tags == null);
}

test "parse collapses extra spaces and strips CRLF" {
    const t = std.testing;
    const m = try Message.parse(":srv  001   bob   :welcome\r\n");
    try t.expectEqualStrings("001", m.command);
    try t.expectEqualStrings("bob", m.params[0]);
    try t.expectEqualStrings("welcome", m.trailing);
}

test "parse PING with leading-colon trailing" {
    const t = std.testing;
    const m = try Message.parse("PING :tok123");
    try t.expectEqualStrings("PING", m.command);
    try t.expectEqualStrings("tok123", m.trailing);
    try t.expectEqualStrings("", m.params[0]);
}

test "parse keeps colon-less single-word tail in params" {
    const t = std.testing;
    const m = try Message.parse(":op!u@h KICK #zig bob bye");
    try t.expectEqualStrings("", m.trailing);
    try t.expectEqualStrings("#zig", m.params[0]);
    try t.expectEqualStrings("bob", m.params[1]);
    try t.expectEqualStrings("bye", m.params[2]);
}

test "parse truncates beyond 15 params" {
    const t = std.testing;
    const m = try Message.parse("CMD a b c d e f g h i j k l m n o p q");
    try t.expectEqualStrings("o", m.params[14]);
    // 16th+ tokens are dropped per RFC 2812; never silently glued.
    for (m.params) |p| try t.expect(std.mem.indexOfScalar(u8, p, ' ') == null);
}

test "parse skips IRCv3 tags without shifting the command" {
    const t = std.testing;
    const m = try Message.parse("@time=2026-10-07T00:00:00.000Z :srv PRIVMSG #zig :hi");
    try t.expectEqualStrings("time=2026-10-07T00:00:00.000Z", m.tags.?);
    try t.expectEqualStrings("srv", m.prefix.?);
    try t.expectEqualStrings("PRIVMSG", m.command);
    try t.expectEqualStrings("#zig", m.params[0]);
    try t.expectEqualStrings("hi", m.trailing);
}

test "parse rejects empty and prefix-only lines" {
    const t = std.testing;
    try t.expectError(error.InvalidMessage, Message.parse(""));
    try t.expectError(error.InvalidMessage, Message.parse("\r\n"));
    try t.expectError(error.InvalidMessage, Message.parse("   "));
    try t.expectError(error.InvalidMessage, Message.parse(":nick-only"));
    try t.expectError(error.InvalidMessage, Message.parse(":nick-only "));
    try t.expectError(error.InvalidMessage, Message.parse("@only-tags-no-space"));
}

test "format round-trips a parsed line" {
    const t = std.testing;
    const m = try Message.parse(":alice!u@h PRIVMSG #zig :hello");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.format(&w);
    try t.expectEqualStrings(":alice!u@h PRIVMSG #zig :hello\r\n", w.buffered());
}

test "format skips empty params and rejects line breaks" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Message{ .command = "PING", .trailing = "tok" }).format(&w);
    try t.expectEqualStrings("PING :tok\r\n", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try t.expectError(error.InvalidMessage, (Message{ .command = "" }).format(&w));
    w = std.Io.Writer.fixed(&buf);
    try t.expectError(error.InvalidMessage, (Message{
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "a\nb",
    }).format(&w));
    w = std.Io.Writer.fixed(&buf);
    try t.expectError(error.InvalidMessage, (Message{
        .command = "PRIVMSG",
        .params = .{"#a\nb"} ++ .{""} ** 14,
    }).format(&w));
}
