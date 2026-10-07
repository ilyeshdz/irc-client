const Message = @import("irc-client").Message;
const fmt = @import("../format.zig");
const Display = @import("mod.zig").Display;
const util = @import("util.zig");

pub fn handleTopic(_: *Display, msg: Message) !void {
    const prefix = msg.prefix orelse return;
    const channel = msg.params[0];
    if (channel.len == 0) return;
    var chb: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    util.event("Topic for {s} changed by {s}: {s}\n", .{ fmt.paintChannel(channel, &chb), fmt.paintNick(util.nickOnly(prefix), &nb), util.reasonOf(msg, 1) });
}

pub fn handleTopicReply(_: *Display, msg: Message) !void {
    // params: [nick, channel]
    if (msg.params[1].len == 0) return;
    var chb: [256]u8 = undefined;
    if (msg.trailing.len > 0) {
        util.line("Topic for {s}: {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), msg.trailing });
    } else {
        util.line("No topic set for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
    }
}

pub fn handleNoTopic(_: *Display, msg: Message) !void {
    // params: [nick, channel]
    if (msg.params[1].len == 0) return;
    var chb: [256]u8 = undefined;
    util.line("No topic set for {s}\n", .{fmt.paintChannel(msg.params[1], &chb)});
}

pub fn handleTopicWhoTime(_: *Display, msg: Message) !void {
    // params: [nick, channel, set-by, timestamp]
    if (msg.params[1].len == 0) return;
    const set_by = msg.params[2];
    const when = msg.params[3];
    var chb: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    if (set_by.len > 0 and when.len > 0) {
        util.line("Topic for {s} set by {s} at {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), fmt.paintNick(set_by, &nb), when });
    } else if (set_by.len > 0) {
        util.line("Topic for {s} set by {s}\n", .{ fmt.paintChannel(msg.params[1], &chb), fmt.paintNick(set_by, &nb) });
    }
}
