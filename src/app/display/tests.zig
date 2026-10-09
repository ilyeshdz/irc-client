const std = @import("std");
const Display = @import("mod.zig").Display;
const hist = @import("../history.zig");
const History = hist.History;
const HistMessage = hist.Message;

test "send errors and local echo are displayed without crashing" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    // 404 when messaging a channel we never joined.
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "404",
        .params = .{ "tester", "#ghost" } ++ .{""} ** 13,
        .trailing = "Cannot send to channel (+n)",
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "421",
        .params = .{ "tester", "FROB" } ++ .{""} ** 13,
        .trailing = "Unknown command",
    });
    d.echoSent("#zig", "hello", false);
    d.echoSent("alice", "hi", false);
    d.echoSent("#zig", "waves", true);
}

test "kick/mode/invite/who numerics display without crashing" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");
    try d.handleServerMessage(.{
        .prefix = "op!u@h",
        .command = "KICK",
        .params = .{ "#zig", "bob" } ++ .{""} ** 13,
        .trailing = "spam",
    });
    try d.handleServerMessage(.{
        .prefix = "op!u@h",
        .command = "MODE",
        .params = .{ "#zig", "+o", "bob" } ++ .{""} ** 12,
        .trailing = "spam",
    });
    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "INVITE",
        .params = .{ "tester", "#zig" } ++ .{""} ** 13,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "352",
        .params = .{ "tester", "#zig", "u", "h", "srv", "bob", "H@" } ++ .{""} ** 8,
        .trailing = "0 Bob",
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "315",
        .params = .{ "tester", "#zig" } ++ .{""} ** 13,
        .trailing = "End of WHO",
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "324",
        .params = .{ "tester", "#zig", "+nt" } ++ .{""} ** 12,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "341",
        .params = .{ "tester", "bob", "#zig" } ++ .{""} ** 12,
    });
    try d.handleServerMessage(.{
        .prefix = "test.local",
        .command = "306",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "You have been marked as being away",
    });
}

test "resetConnectionState clears what a dropped connection left behind" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    d.collecting_motd = true;
    try d.motd_buffer.appendSlice(t.allocator, "half a motd");
    d.beginList();
    d.list_count = 7;
    d.in_channel_list = true;

    d.resetConnectionState();

    try t.expect(!d.collecting_motd);
    try t.expectEqual(@as(usize, 0), d.motd_buffer.items.len);
    try t.expect(!d.list_pending);
    try t.expect(!d.list_refused);
    try t.expect(!d.in_channel_list);
    try t.expectEqual(@as(usize, 0), d.list_count);
    // The conversation we were in is unaffected.
    try t.expectEqualStrings("tester", d.current_nick.?);
}

test "local status lines print without a server behind them" {
    var d = try Display.init(std.testing.allocator);
    defer d.deinit();
    d.info("reconnecting to {s}:{d}…\n", .{ "irc.example.org", 6667 });
    d.err("connection lost\n", .{});
    d.reconnected();
}

test "incoming and outgoing messages are recorded into history" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "hello there",
    });
    try d.handleServerMessage(.{
        .prefix = "bob!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "\x01ACTION waves\x01",
    });
    // Incoming PM: recorded under the sender's nick, not our own.
    try d.handleServerMessage(.{
        .prefix = "carol!u@h",
        .command = "PRIVMSG",
        .params = .{"tester"} ++ .{""} ** 14,
        .trailing = "psst",
    });
    d.echoSent("#zig", "hi back", false);
    d.echoSent("#zig", "nods", true);
    d.echoSent("carol", "secret", false);

    try t.expectEqual(@as(usize, 1), h.servers.items.len);
    try t.expectEqualStrings("irc.libera.chat", h.servers.items[0].ip);
    try t.expectEqual(@as(usize, 2), h.servers.items[0].channels.items.len);

    const zig = h.servers.items[0].channels.items[0];
    try t.expectEqualStrings("#zig", zig.name);
    try t.expectEqual(@as(usize, 4), zig.messages.items.len);
    try t.expectEqualStrings("alice", zig.messages.items[0].sender);
    try t.expectEqualStrings("hello there", zig.messages.items[0].content);
    try t.expectEqualStrings("bob", zig.messages.items[1].sender);
    try t.expectEqualStrings("\x01ACTION waves\x01", zig.messages.items[1].content);
    try t.expectEqualStrings("tester", zig.messages.items[2].sender);
    try t.expectEqualStrings("hi back", zig.messages.items[2].content);
    try t.expectEqualStrings("tester", zig.messages.items[3].sender);
    try t.expectEqualStrings("\x01ACTION nods\x01", zig.messages.items[3].content);

    const carol = h.servers.items[0].channels.items[1];
    try t.expectEqualStrings("carol", carol.name);
    try t.expectEqual(@as(usize, 2), carol.messages.items.len);
    try t.expectEqualStrings("carol", carol.messages.items[0].sender);
    try t.expectEqualStrings("psst", carol.messages.items[0].content);
    try t.expectEqualStrings("secret", carol.messages.items[1].content);
}

test "history save failures do not break the display" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    // /dev/null is a file, so writing below it always fails (ENOTDIR).
    h.path = try t.allocator.dupe(u8, "/dev/null/history");
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "alice!u@h",
        .command = "PRIVMSG",
        .params = .{"#zig"} ++ .{""} ** 14,
        .trailing = "unsaved",
    });
    d.echoSent("#zig", "also unsaved", false);

    // Reported once, and the message still landed in memory.
    try t.expect(d.history_warned);
    try t.expectEqual(@as(usize, 1), h.servers.items.len);
    try t.expectEqual(@as(usize, 2), h.servers.items[0].channels.items[0].messages.items.len);
}

test "joining a channel replays its saved history exactly once" {
    const t = std.testing;
    var d = try Display.init(t.allocator);
    defer d.deinit();
    try d.setCurrentNick("tester");

    var h = History.initWithPath(t.allocator, t.io, null);
    defer h.deinit();
    try h.addMessage("irc.libera.chat", "#zig", HistMessage.init("alice", 1717000000, "earlier"));
    try h.addMessage("irc.libera.chat", "#zig", HistMessage.init("bob", 1717000001, "and now"));
    try d.setHistory(&h, "irc.libera.chat");

    try d.handleServerMessage(.{
        .prefix = "tester!u@h",
        .command = "JOIN",
        .params = .{"#zig"} ++ .{""} ** 14,
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
    try t.expectEqualStrings("#zig", d.replayed.items[0]);
    try t.expectEqualStrings("#zig", d.current_channel.?);

    // Rejoining must not repeat the scrollback.
    try d.handleServerMessage(.{
        .prefix = "tester!u@h",
        .command = "JOIN",
        .params = .{"#zig"} ++ .{""} ** 14,
    });
    try t.expectEqual(@as(usize, 1), d.replayed.items.len);
}
