const std = @import("std");
const out = @import("../out.zig");
const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const chat = @import("chat.zig");
const util = @import("util.zig");

pub fn handleListStart(self: *Display, _: Message) !void {
    self.in_channel_list = true;
    if (fmt.isEnabled()) {
        out.print("\n{s}{s}channels{s}  {s}users  topic{s}\n", .{ fmt.bold, fmt.cyan, fmt.reset, fmt.dim, fmt.reset });
        out.print("{s}─────────────────────────────{s}\n", .{ fmt.dim, fmt.reset });
    } else {
        out.print("\n--- Channels ---\n", .{});
    }
}

pub fn handleListLine(self: *Display, msg: Message) !void {
    if (!self.in_channel_list and !self.list_pending) return;
    // params: [nick, channel, usercount]
    const channel = msg.params[1];
    const users = msg.params[2];
    if (channel.len == 0) return;
    self.list_count += 1;
    const topic = if (msg.trailing.len > 0) msg.trailing else "(no topic)";
    var chb: [256]u8 = undefined;
    util.line("{s}  {s}  {s}\n", .{ fmt.paintChannel(channel, &chb), users, topic });
}

pub fn handleListEnd(self: *Display, _: Message) !void {
    if (self.in_channel_list) {
        self.in_channel_list = false;
        if (fmt.isEnabled()) {
            out.print("{s}─────────────────────────────{s}\n\n", .{ fmt.dim, fmt.reset });
        } else {
            out.print("------------------\n\n", .{});
        }
    } else if (self.list_refused) {
        util.errLine("Channel listing refused by the server (LIST is restricted here)\n\n", .{});
    } else if (self.list_count == 0) {
        util.line("No channels found\n\n", .{});
    }
    self.list_pending = false;
    self.list_refused = false;
}

/// Detects server notices telling us the channel listing was refused
/// (e.g. IRCnet's "/list is deprecated" notice) while a list is pending.
pub fn noteListRefusal(self: *Display, text: []const u8) void {
    if (!self.list_pending or self.list_count > 0) return;
    if (containsCaseInsensitive(text, "deprecat") or
        containsCaseInsensitive(text, "too large") or
        containsCaseInsensitive(text, "truncat"))
    {
        self.list_refused = true;
    }
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "refused LIST reports refusal instead of empty list" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    d.beginList();
    // IRCnet-style deprecation notice received while the list is pending.
    try chat.handleNotice(&d, .{
        .prefix = "ircnet.tngnet.nl",
        .command = "NOTICE",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "Usage of /list for listing all channels is deprecated.",
    });
    try t.expect(d.list_refused);
    // Server ends the list without any channel.
    try handleListEnd(&d, .{
        .prefix = "ircnet.tngnet.nl",
        .command = "323",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "End of LIST",
    });
    try t.expect(!d.list_pending);
}

test "empty LIST without refusal stays a plain empty list" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    d.beginList();
    try handleListEnd(&d, .{
        .prefix = "test.local",
        .command = "323",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "End of LIST",
    });
    try t.expect(!d.list_pending);
    try t.expect(!d.list_refused);
}
