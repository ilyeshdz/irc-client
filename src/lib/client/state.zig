const std = @import("std");
const Message = @import("../message.zig").Message;
const IrcClient = @import("mod.zig").IrcClient;

/// Set the current channel for default message targeting.
/// Takes ownership of a copy; passing null or an empty slice clears it.
pub fn setCurrentChannel(self: *IrcClient, channel: ?[]const u8) !void {
    if (self.current_channel) |c| {
        self.allocator.free(c);
        self.current_channel = null;
    }
    if (channel) |ch| {
        if (ch.len > 0) self.current_channel = try self.allocator.dupe(u8, ch);
    }
}

/// Get the current channel (null when not in a channel;
/// never returns an empty slice).
pub fn getCurrentChannel(self: *IrcClient) ?[]const u8 {
    if (self.current_channel) |c| {
        if (c.len == 0) return null;
        return c;
    }
    return null;
}

/// Follow our own JOIN/PART/KICK so `channels` and `current_channel` stay
/// right even for `/raw JOIN` or a server-side kick: what the server says
/// we are in is what a reconnect should rejoin.
pub fn syncMembership(self: *IrcClient, msg: Message) void {
    // For KICK the prefix is the kicker; the kicked nick is params[1].
    if (std.mem.eql(u8, msg.command, "KICK")) {
        if (isSelfNick(self, msg.params[1])) leaveChannel(self, msg.params[0]);
        return;
    }

    const prefix = msg.prefix orelse return;
    if (!isSelfNick(self, prefix)) return;
    const channel = msg.params[0];
    if (channel.len == 0) return;

    if (std.mem.eql(u8, msg.command, "JOIN")) {
        rememberChannel(self, channel) catch |err| std.log.warn("could not remember channel {s}: {s}", .{ channel, @errorName(err) });
        setCurrentChannel(self, channel) catch |err| std.log.warn("could not target channel {s}: {s}", .{ channel, @errorName(err) });
    } else if (std.mem.eql(u8, msg.command, "PART")) {
        leaveChannel(self, channel);
    }
}

/// `nick_or_prefix` may be a bare nick or a `nick!user@host` prefix.
fn isSelfNick(self: *const IrcClient, nick_or_prefix: []const u8) bool {
    if (self.current_nick.len == 0) return false;
    const nick = if (std.mem.indexOfScalar(u8, nick_or_prefix, '!')) |i|
        nick_or_prefix[0..i]
    else
        nick_or_prefix;
    return std.mem.eql(u8, nick, self.current_nick);
}

/// Forget a channel we just left; drop it as the current target too.
fn leaveChannel(self: *IrcClient, channel: []const u8) void {
    forgetChannel(self, channel);
    if (getCurrentChannel(self)) |current| {
        if (std.mem.eql(u8, current, channel)) setCurrentChannel(self, null) catch |err| {
            std.log.warn("could not clear current channel after leaving {s}: {s}", .{ channel, @errorName(err) });
        };
    }
}

pub fn rememberChannel(self: *IrcClient, channel: []const u8) !void {
    if (channel.len == 0) return;
    for (self.channels.items) |c| {
        if (std.mem.eql(u8, c, channel)) return;
    }
    const owned = try self.allocator.dupe(u8, channel);
    errdefer self.allocator.free(owned);
    try self.channels.append(self.allocator, owned);
}

pub fn forgetChannel(self: *IrcClient, channel: []const u8) void {
    for (self.channels.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c, channel)) continue;
        self.allocator.free(c);
        _ = self.channels.orderedRemove(i);
        return;
    }
}

test "joined channels are remembered once and dropped on part" {
    // No socket needed: only the bookkeeping is exercised.
    var client = IrcClient.initForTest(std.testing.allocator);
    defer client.deinit();

    try rememberChannel(&client, "#zig");
    try rememberChannel(&client, "#zig");
    try rememberChannel(&client, "#rust");
    try std.testing.expectEqual(@as(usize, 2), client.channels.items.len);

    forgetChannel(&client, "#zig");
    forgetChannel(&client, "#zig");
    try std.testing.expectEqual(@as(usize, 1), client.channels.items.len);
    try std.testing.expectEqualStrings("#rust", client.channels.items[0]);

    try rememberChannel(&client, "");
    try std.testing.expectEqual(@as(usize, 1), client.channels.items.len);
}

test "our own JOIN/PART/KICK decide what a reconnect rejoins" {
    const t = std.testing;
    var client = IrcClient.initForTest(t.allocator);
    defer client.deinit();
    try client.replaceOwned(&client.current_nick, "tester");

    // Someone else joining must not touch our membership.
    syncMembership(&client, try Message.parse(":alice!a@h JOIN #zig"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);

    // /raw JOIN goes through the server, not through joinChannel().
    syncMembership(&client, try Message.parse(":tester!u@h JOIN #zig"));
    try t.expectEqual(@as(usize, 1), client.channels.items.len);
    try t.expectEqualStrings("#zig", getCurrentChannel(&client).?);

    // Another channel joined the same way, then a server-side kick.
    syncMembership(&client, try Message.parse(":tester!u@h JOIN #rust"));
    try t.expectEqual(@as(usize, 2), client.channels.items.len);
    syncMembership(&client, try Message.parse(":op!o@h KICK #zig tester :bye"));
    try t.expectEqualStrings("#rust", getCurrentChannel(&client).?);
    try t.expectEqual(@as(usize, 1), client.channels.items.len);

    // Our own PART forgets the channel; someone else's PART does not.
    syncMembership(&client, try Message.parse(":tester!u@h PART #rust"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);
    try t.expect(getCurrentChannel(&client) == null);
    syncMembership(&client, try Message.parse(":alice!u@h PART #rust"));
    try t.expectEqual(@as(usize, 0), client.channels.items.len);
}
