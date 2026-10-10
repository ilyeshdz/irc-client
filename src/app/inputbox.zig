const std = @import("std");
const out = @import("out.zig");
const format = @import("format.zig");

/// Minimal bottom-of-screen input box: raw-mode line editing, prompt
/// redrawn under server output. No fullscreen TUI. On pipes (not a tty)
/// raw mode stays off and the caller reads plain lines.
///
/// Up/Down (and Ctrl-P/Ctrl-N) recall previously submitted lines; the
/// in-progress line is kept as a draft and restored when coming back down.
pub const InputBox = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    raw: bool = false,
    orig: std.posix.termios = undefined,
    esc_state: u2 = 0,
    hist_storage: [max_history][1024]u8 = undefined,
    hist_lens: [max_history]usize = undefined,
    hist_head: usize = 0,
    hist_len: usize = 0,
    /// 0 = editing a fresh line, 1..hist_len = how far back from newest.
    hist_pos: usize = 0,
    draft: [1024]u8 = undefined,
    draft_len: usize = 0,
    has_draft: bool = false,

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
        out.print("\r\x1b[K", .{});
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig) catch |err| std.log.debug("could not restore terminal mode: {s}", .{@errorName(err)});
    }

    pub const Key = union(enum) {
        none,
        line: []const u8,
        interrupt,
        eof,
    };

    /// Feed one raw byte: completed line on Enter, interrupt on Ctrl-C,
    /// eof on Ctrl-D with an empty buffer. Up/Down recall history;
    /// other escape sequences are swallowed.
    pub fn feedByte(self: *InputBox, b: u8) Key {
        if (self.esc_state == 1) {
            self.esc_state = if (b == '[') 2 else 0;
            return .none;
        }
        if (self.esc_state == 2) {
            // CSI final byte is in @-~ range.
            if (b >= 0x40 and b <= 0x7e) {
                self.esc_state = 0;
                if (b == 'A') self.recallOlder();
                if (b == 'B') self.recallNewer();
            }
            return .none;
        }
        switch (b) {
            0x1b => {
                self.esc_state = 1;
                return .none;
            },
            '\r', '\n' => {
                const submitted = self.buf[0..self.len];
                self.pushHistory(submitted);
                self.len = 0;
                return .{ .line = submitted };
            },
            0x03 => return .interrupt,
            0x04 => {
                if (self.len == 0) return .eof;
                return .none;
            },
            0x10 => { // Ctrl-P: previous history entry, like Up
                self.recallOlder();
                return .none;
            },
            0x0e => { // Ctrl-N: next history entry, like Down
                self.recallNewer();
                return .none;
            },
            0x15 => { // Ctrl-U: clear line
                self.len = 0;
                self.cancelBrowse();
                return .none;
            },
            0x7f, 0x08 => { // Backspace: erase one full UTF-8 codepoint
                while (self.len > 0 and isContinuation(self.buf[self.len - 1])) self.len -= 1;
                if (self.len > 0) self.len -= 1;
                self.cancelBrowse();
                return .none;
            },
            else => {
                if (b >= 0x20 and self.len < self.buf.len) {
                    self.buf[self.len] = b;
                    self.len += 1;
                    self.cancelBrowse();
                }
                return .none;
            },
        }
    }

    fn isContinuation(b: u8) bool {
        return b >= 0x80 and b < 0xc0;
    }

    /// Lines kept for Up/Down recall. Fixed ring like InputQueue, but the
    /// oldest entry is overwritten: history must never refuse a new line.
    pub const max_history = 50;

    /// Remember a submitted line. Empty lines and consecutive duplicates
    /// are skipped so Up never shows blank or repeated entries.
    fn pushHistory(self: *InputBox, line: []const u8) void {
        self.hist_pos = 0;
        self.has_draft = false;
        if (line.len == 0 or line.len > self.hist_storage[0].len) return;
        if (self.hist_len > 0 and std.mem.eql(u8, self.newest(), line)) return;
        if (self.hist_len < max_history) {
            const tail = (self.hist_head + self.hist_len) % max_history;
            @memcpy(self.hist_storage[tail][0..line.len], line);
            self.hist_lens[tail] = line.len;
            self.hist_len += 1;
        } else {
            @memcpy(self.hist_storage[self.hist_head][0..line.len], line);
            self.hist_lens[self.hist_head] = line.len;
            self.hist_head = (self.hist_head + 1) % max_history;
        }
    }

    fn newest(self: *const InputBox) []const u8 {
        const idx = (self.hist_head + self.hist_len - 1) % max_history;
        return self.hist_storage[idx][0..self.hist_lens[idx]];
    }

    fn atBack(self: *const InputBox, back: usize) []const u8 {
        // back=1 is the newest entry, back=hist_len the oldest.
        const idx = (self.hist_head + self.hist_len - back) % max_history;
        return self.hist_storage[idx][0..self.hist_lens[idx]];
    }

    fn loadIntoBuf(self: *InputBox, line: []const u8) void {
        @memcpy(self.buf[0..line.len], line);
        self.len = line.len;
    }

    /// Up: stash the in-progress line once, then walk toward older entries.
    fn recallOlder(self: *InputBox) void {
        if (self.hist_len == 0 or self.hist_pos >= self.hist_len) return;
        if (self.hist_pos == 0) {
            @memcpy(self.draft[0..self.len], self.buf[0..self.len]);
            self.draft_len = self.len;
            self.has_draft = true;
        }
        self.hist_pos += 1;
        self.loadIntoBuf(self.atBack(self.hist_pos));
    }

    /// Down: walk back toward the draft, restoring it at the end.
    fn recallNewer(self: *InputBox) void {
        if (self.hist_pos == 0) return;
        self.hist_pos -= 1;
        if (self.hist_pos == 0) {
            if (self.has_draft) {
                @memcpy(self.buf[0..self.draft_len], self.draft[0..self.draft_len]);
                self.len = self.draft_len;
                self.has_draft = false;
            } else {
                self.len = 0;
            }
        } else {
            self.loadIntoBuf(self.atBack(self.hist_pos));
        }
    }

    /// Any edit leaves history browsing: what is on screen is a new line.
    fn cancelBrowse(self: *InputBox) void {
        self.hist_pos = 0;
        self.has_draft = false;
    }

    pub fn hide(self: *InputBox) void {
        if (!self.raw) return;
        out.print("\r\x1b[K", .{});
    }

    pub fn show(self: *InputBox, channel: ?[]const u8, nick: []const u8) void {
        if (!self.raw) return;
        if (format.isEnabled()) {
            var chb: [256]u8 = undefined;
            var nb: [256]u8 = undefined;
            const where = if (channel) |ch| format.paintChannel(ch, &chb) else "(lobby)";
            out.print("\r\x1b[K{s} {s} {s}›{s} {s}", .{
                where,
                format.dim,
                format.paintNick(nick, &nb),
                format.reset,
                self.buf[0..self.len],
            });
        } else {
            const where = channel orelse "(lobby)";
            out.print("\r\x1b[K{s} {s} › {s}", .{ where, nick, self.buf[0..self.len] });
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
    for ("aé") |c| _ = box.feedByte(c);
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

fn submitText(box: *InputBox, text: []const u8) void {
    for (text) |c| _ = box.feedByte(c);
    const key = box.feedByte('\r');
    std.testing.expect(key == .line) catch unreachable;
}

fn pressUp(box: *InputBox) void {
    for ("\x1b[A") |c| _ = box.feedByte(c);
}

fn pressDown(box: *InputBox) void {
    for ("\x1b[B") |c| _ = box.feedByte(c);
}

test "up recalls previous lines, down restores the draft" {
    const t = std.testing;
    var box: InputBox = .{};
    submitText(&box, "first");
    submitText(&box, "second");

    pressUp(&box);
    try t.expectEqualStrings("second", box.buf[0..box.len]);
    pressUp(&box);
    try t.expectEqualStrings("first", box.buf[0..box.len]);
    // Past the oldest entry: the line stays put.
    pressUp(&box);
    try t.expectEqualStrings("first", box.buf[0..box.len]);

    pressDown(&box);
    try t.expectEqualStrings("second", box.buf[0..box.len]);
    pressDown(&box);
    try t.expectEqual(@as(usize, 0), box.len);
}

test "in-progress line is kept as a draft while browsing" {
    const t = std.testing;
    var box: InputBox = .{};
    submitText(&box, "saved");
    for ("dra") |c| _ = box.feedByte(c);

    pressUp(&box);
    try t.expectEqualStrings("saved", box.buf[0..box.len]);
    pressDown(&box);
    try t.expectEqualStrings("dra", box.buf[0..box.len]);
}

test "empty lines and consecutive duplicates are not stored" {
    const t = std.testing;
    var box: InputBox = .{};
    _ = box.feedByte('\r');
    try t.expectEqual(@as(usize, 0), box.hist_len);
    submitText(&box, "same");
    submitText(&box, "same");
    try t.expectEqual(@as(usize, 1), box.hist_len);

    pressUp(&box);
    try t.expectEqualStrings("same", box.buf[0..box.len]);
    pressUp(&box);
    try t.expectEqualStrings("same", box.buf[0..box.len]);
}

test "editing a recalled line starts a new line" {
    const t = std.testing;
    var box: InputBox = .{};
    submitText(&box, "hello");
    pressUp(&box);
    try t.expectEqualStrings("hello", box.buf[0..box.len]);
    _ = box.feedByte('!');
    try t.expectEqualStrings("hello!", box.buf[0..box.len]);
    // Browsing was left: Down no longer restores anything.
    pressDown(&box);
    try t.expectEqualStrings("hello!", box.buf[0..box.len]);
}

test "ctrl-p and ctrl-n walk history like up and down" {
    const t = std.testing;
    var box: InputBox = .{};
    submitText(&box, "one");
    submitText(&box, "two");
    _ = box.feedByte(0x10);
    try t.expectEqualStrings("two", box.buf[0..box.len]);
    _ = box.feedByte(0x10);
    try t.expectEqualStrings("one", box.buf[0..box.len]);
    _ = box.feedByte(0x0e);
    try t.expectEqualStrings("two", box.buf[0..box.len]);
}

test "full history overwrites the oldest entry" {
    const t = std.testing;
    var box: InputBox = .{};
    var i: usize = 0;
    while (i < InputBox.max_history + 1) : (i += 1) {
        var tmp: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&tmp, "l{d}", .{i});
        submitText(&box, text);
    }
    try t.expectEqual(InputBox.max_history, box.hist_len);
    // l0 was evicted: the oldest entry is now l1.
    pressUp(&box);
    var j: usize = 0;
    while (j < InputBox.max_history - 1) : (j += 1) pressUp(&box);
    try t.expectEqualStrings("l1", box.buf[0..box.len]);
}
