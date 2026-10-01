const std = @import("std");
const format = @import("format.zig");

/// A minimal bottom-of-screen input box: raw-mode line editing with the
/// prompt redrawn under server output. No fullscreen TUI, no external deps.
/// When stdin is not a tty (pipes), raw mode stays off and the caller falls
/// back to plain line reading.
pub const InputBox = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    raw: bool = false,
    orig: std.posix.termios = undefined,
    esc_state: u2 = 0,

    pub fn init() InputBox {
        var self: InputBox = .{};
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return self;
        self.orig = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return self;
        var raw = self.orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return self;
        self.raw = true;
        return self;
    }

    pub fn deinit(self: *InputBox) void {
        if (!self.raw) return;
        self.raw = false;
        // Clear the prompt line, then restore cooked mode.
        std.debug.print("\r\x1b[K", .{});
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
    }

    pub const Key = union(enum) {
        none,
        line: []const u8,
        interrupt,
        eof,
    };

    /// Feed one raw byte. Returns a completed line on Enter, interrupt on
    /// Ctrl-C, eof on Ctrl-D with an empty buffer. Escape sequences
    /// (arrows, etc.) are swallowed.
    pub fn feedByte(self: *InputBox, b: u8) Key {
        if (self.esc_state == 1) {
            self.esc_state = if (b == '[') 2 else 0;
            return .none;
        }
        if (self.esc_state == 2) {
            // CSI ... final byte is in @-~ range.
            if (b >= 0x40 and b <= 0x7e) self.esc_state = 0;
            return .none;
        }
        switch (b) {
            0x1b => {
                self.esc_state = 1;
                return .none;
            },
            '\r', '\n' => {
                const submitted = self.buf[0..self.len];
                self.len = 0;
                return .{ .line = submitted };
            },
            0x03 => return .interrupt,
            0x04 => {
                if (self.len == 0) return .eof;
                return .none;
            },
            0x15 => { // Ctrl-U: clear line
                self.len = 0;
                return .none;
            },
            0x7f, 0x08 => { // Backspace: erase one full UTF-8 codepoint
                while (self.len > 0 and isContinuation(self.buf[self.len - 1])) self.len -= 1;
                if (self.len > 0) self.len -= 1;
                return .none;
            },
            else => {
                if (b >= 0x20 and self.len < self.buf.len) {
                    self.buf[self.len] = b;
                    self.len += 1;
                }
                return .none;
            },
        }
    }

    fn isContinuation(b: u8) bool {
        return b >= 0x80 and b < 0xc0;
    }

    /// Erase the prompt line so server output can print above it.
    pub fn hide(self: *InputBox) void {
        if (!self.raw) return;
        std.debug.print("\r\x1b[K", .{});
    }

    /// Redraw the prompt line with the current buffer.
    pub fn show(self: *InputBox, channel: ?[]const u8, nick: []const u8) void {
        if (!self.raw) return;
        if (format.isEnabled()) {
            var chb: [256]u8 = undefined;
            var nb: [256]u8 = undefined;
            const where = if (channel) |ch| format.paintChannel(ch, &chb) else "(lobby)";
            std.debug.print("\r\x1b[K{s} {s} {s}›{s} {s}", .{
                where,
                format.dim,
                format.paintNick(nick, &nb),
                format.reset,
                self.buf[0..self.len],
            });
        } else {
            const where = channel orelse "(lobby)";
            std.debug.print("\r\x1b[K{s} {s} › {s}", .{ where, nick, self.buf[0..self.len] });
        }
    }
};

test "typing then enter submits the line" {
    var box: InputBox = .{};
    for ("hi") |c| try std.testing.expect(box.feedByte(c) == .none);
    const key = box.feedByte('\r');
    try std.testing.expectEqualStrings("hi", key.line);
    try std.testing.expectEqual(@as(usize, 0), box.len);
}

test "backspace erases one utf-8 codepoint" {
    var box: InputBox = .{};
    for ("aé") |c| _ = box.feedByte(c); // é is 2 bytes in UTF-8
    _ = box.feedByte(0x7f);
    try std.testing.expectEqualStrings("a", box.buf[0..box.len]);
    _ = box.feedByte(0x7f);
    try std.testing.expectEqual(@as(usize, 0), box.len);
}

test "ctrl-u clears and escape sequences are swallowed" {
    var box: InputBox = .{};
    for ("hello") |c| _ = box.feedByte(c);
    _ = box.feedByte(0x15);
    try std.testing.expectEqual(@as(usize, 0), box.len);
    for ("\x1b[A\x1b[1~") |c| try std.testing.expect(box.feedByte(c) == .none);
    try std.testing.expectEqual(@as(usize, 0), box.len);
}

test "ctrl-c interrupts and ctrl-d ends empty input" {
    var box: InputBox = .{};
    try std.testing.expect(box.feedByte(0x03) == .interrupt);
    try std.testing.expect(box.feedByte(0x04) == .eof);
    _ = box.feedByte('x');
    try std.testing.expect(box.feedByte(0x04) == .none);
}

test "buffer overflow is ignored, not wrapped" {
    var box: InputBox = .{};
    for (0..1100) |_| _ = box.feedByte('a');
    try std.testing.expectEqual(@as(usize, 1024), box.len);
}
