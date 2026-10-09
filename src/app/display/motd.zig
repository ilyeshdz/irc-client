const std = @import("std");
const out = @import("../out.zig");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleMOTDStart(self: *Display, msg: Message) !void {
    self.collecting_motd = true;
    self.motd_buffer.clearRetainingCapacity();
    if (msg.trailing.len > 0) {
        try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
        try self.motd_buffer.appendSlice(self.allocator, "\n");
    }
}

pub fn handleMOTDLine(self: *Display, msg: Message) !void {
    if (self.collecting_motd and msg.trailing.len > 0) {
        try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
        try self.motd_buffer.appendSlice(self.allocator, "\n");
    }
}

pub fn handleMOTDEnd(self: *Display, msg: Message) !void {
    if (!self.collecting_motd) return;
    self.collecting_motd = false;
    if (msg.trailing.len > 0) {
        try self.motd_buffer.appendSlice(self.allocator, msg.trailing);
        try self.motd_buffer.appendSlice(self.allocator, "\n");
    }
    printMOTD(self);
}

fn printMOTD(self: *Display) void {
    const motd = std.mem.trimEnd(u8, self.motd_buffer.items, "\n");
    if (fmt.isEnabled()) {
        out.print("\n{s}╭─ MOTD ─────────────{s}\n", .{ fmt.cyan, fmt.reset });
    } else {
        out.print("\n--- MOTD ---\n", .{});
    }
    if (motd.len > 0) {
        var it = std.mem.splitScalar(u8, motd, '\n');
        while (it.next()) |l| {
            if (fmt.isEnabled()) {
                out.print("{s}│{s} {s}\n", .{ fmt.cyan, fmt.reset, l });
            } else {
                out.print("{s}\n", .{l});
            }
        }
    } else {
        util.line("(empty)\n", .{});
    }
    if (fmt.isEnabled()) {
        out.print("{s}╰────────────────────{s}\n\n", .{ fmt.cyan, fmt.reset });
    } else {
        out.print("------------\n\n", .{});
    }
}

test "motd collects lines between start and end" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();

    try handleMOTDLine(&d, .{ .command = "372", .trailing = "stray" });
    try t.expectEqual(@as(usize, 0), d.motd_buffer.items.len);

    try handleMOTDStart(&d, .{ .command = "375", .trailing = "start" });
    try handleMOTDLine(&d, .{ .command = "372", .trailing = "hello" });
    try handleMOTDLine(&d, .{ .command = "372", .trailing = "world" });
    try t.expect(d.collecting_motd);
    try handleMOTDEnd(&d, .{ .command = "376", .trailing = "end" });
    try t.expect(!d.collecting_motd);
    try t.expectEqualStrings("start\nhello\nworld\nend\n", d.motd_buffer.items);
}
