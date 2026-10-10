const std = @import("std");

pub const Command = union(enum) {
    Join: []const u8,
    Part: struct { channel: []const u8, reason: ?[]const u8 },
    Cycle: struct { channel: ?[]const u8, reason: ?[]const u8 },
    Msg: struct { target: []const u8, text: []const u8 },
    Notice: struct { target: []const u8, text: []const u8 },
    Query: []const u8,
    Close: ?[]const u8,
    Raw: struct { command: []const u8, params: []const u8 },
    Quit: ?[]const u8,
    Reconnect,
    Help,
    List,
    Nick: []const u8,
    Topic: struct { channel: []const u8, text: ?[]const u8 },
    Names: ?[]const u8,
    Whois: []const u8,
    Who: []const u8,
    Mode: struct { target: []const u8, modes: ?[]const u8 },
    Kick: struct { channel: []const u8, nick: []const u8, reason: ?[]const u8 },
    Invite: struct { nick: []const u8, channel: []const u8 },
    Away: ?[]const u8,
    Me: struct { target: ?[]const u8, text: []const u8 },
    Unknown: []const u8,

    pub fn parse(input: []const u8, current_channel: ?[]const u8) !?Command {
        const trimmed = std.mem.trim(u8, input, " \r\n\t");
        if (trimmed.len == 0) return null;

        if (!std.mem.startsWith(u8, trimmed, "/")) {
            if (current_channel) |chan| {
                if (chan.len == 0) return error.NoCurrentChannel;
                return Command{ .Msg = .{ .target = chan, .text = trimmed } };
            }
            return error.NoCurrentChannel;
        }

        // Split "/cmd args..."; the slices borrow `trimmed`, no allocation.
        const without_slash = trimmed[1..];
        const cmd_end = std.mem.indexOfScalar(u8, without_slash, ' ') orelse without_slash.len;
        const cmd = without_slash[0..cmd_end];
        var args = std.mem.trimStart(u8, without_slash[cmd_end..], " ");

        const Kind = enum {
            join,
            list,
            part,
            cycle,
            msg,
            notice,
            query,
            close,
            raw,
            quit,
            reconnect,
            nick,
            topic,
            names,
            whois,
            who,
            mode,
            kick,
            invite,
            away,
            me,
            help,
        };

        // Zig can't switch on a []u8: resolve the name and its shortcut to
        // an enum first. Add a row here to support a new command.
        const commands = std.StaticStringMap(Kind).initComptime(.{
            .{ "join", .join },
            .{ "j", .join },
            .{ "list", .list },
            .{ "l", .list },
            .{ "part", .part },
            .{ "p", .part },
            .{ "cycle", .cycle },
            .{ "msg", .msg },
            .{ "m", .msg },
            .{ "privmsg", .msg },
            .{ "notice", .notice },
            .{ "query", .query },
            .{ "close", .close },
            .{ "raw", .raw },
            .{ "r", .raw },
            .{ "quit", .quit },
            .{ "q", .quit },
            .{ "reconnect", .reconnect },
            .{ "nick", .nick },
            .{ "n", .nick },
            .{ "topic", .topic },
            .{ "t", .topic },
            .{ "names", .names },
            .{ "whois", .whois },
            .{ "w", .whois },
            .{ "who", .who },
            .{ "mode", .mode },
            .{ "kick", .kick },
            .{ "k", .kick },
            .{ "invite", .invite },
            .{ "i", .invite },
            .{ "away", .away },
            .{ "me", .me },
            .{ "help", .help },
            .{ "h", .help },
        });

        const kind = commands.get(cmd) orelse return Command{ .Unknown = cmd };
        switch (kind) {
            .join => {
                const channel = nextToken(&args) orelse return error.MissingArgument;
                return Command{ .Join = channel };
            },
            .list => {
                return Command{ .List = {} };
            },
            .part => {
                const channel = nextToken(&args) orelse return error.MissingArgument;
                const reason = restOrNull(&args);
                return Command{ .Part = .{ .channel = channel, .reason = reason } };
            },
            .cycle => {
                const all_args = args;
                const first = nextToken(&args);
                const first_token = first orelse return Command{ .Cycle = .{ .channel = null, .reason = null } };
                if (isChannelName(first_token)) {
                    return Command{ .Cycle = .{ .channel = first_token, .reason = restOrNull(&args) } };
                }
                // A non-channel word targets the current channel: the whole
                // tail is the reason (`/cycle brb` or `/cycle brb now`).
                // Without a current channel it names a channel instead.
                if (current_channel) |chan| {
                    if (chan.len != 0) return Command{ .Cycle = .{ .channel = null, .reason = all_args } };
                }
                return Command{ .Cycle = .{ .channel = first_token, .reason = restOrNull(&args) } };
            },
            .msg => {
                const target = nextToken(&args) orelse return error.MissingArgument;
                const text = restOrNull(&args) orelse return error.MissingArgument;
                return Command{ .Msg = .{ .target = target, .text = text } };
            },
            .notice => {
                const target = nextToken(&args) orelse return error.MissingArgument;
                const text = restOrNull(&args) orelse return error.MissingArgument;
                return Command{ .Notice = .{ .target = target, .text = text } };
            },
            .query => {
                const nick = nextToken(&args) orelse return error.MissingArgument;
                return Command{ .Query = nick };
            },
            .close => {
                const nick = nextToken(&args);
                return Command{ .Close = nick };
            },
            .raw => {
                const command = nextToken(&args) orelse return error.MissingArgument;
                const params = restOrNull(&args) orelse "";
                return Command{ .Raw = .{ .command = command, .params = params } };
            },
            .quit => {
                const reason = restOrNull(&args);
                return Command{ .Quit = reason };
            },
            .reconnect => {
                return Command{ .Reconnect = {} };
            },
            .nick => {
                const nick = nextToken(&args) orelse return error.MissingArgument;
                return Command{ .Nick = nick };
            },
            .topic => {
                const channel = nextToken(&args) orelse {
                    if (current_channel) |chan| {
                        if (chan.len == 0) return error.MissingArgument;
                        return Command{ .Topic = .{ .channel = chan, .text = null } };
                    }
                    return error.MissingArgument;
                };
                const text = restOrNull(&args);
                return Command{ .Topic = .{ .channel = channel, .text = text } };
            },
            .names => {
                const channel = nextToken(&args);
                return Command{ .Names = channel };
            },
            .whois => {
                const nick = nextToken(&args) orelse return error.MissingArgument;
                return Command{ .Whois = nick };
            },
            .who => {
                const target = nextToken(&args) orelse {
                    if (current_channel) |chan| {
                        if (chan.len == 0) return error.MissingArgument;
                        return Command{ .Who = chan };
                    }
                    return error.MissingArgument;
                };
                return Command{ .Who = target };
            },
            .mode => {
                const target = nextToken(&args) orelse {
                    if (current_channel) |chan| {
                        if (chan.len == 0) return error.MissingArgument;
                        return Command{ .Mode = .{ .target = chan, .modes = null } };
                    }
                    return error.MissingArgument;
                };
                const modes = restOrNull(&args);
                return Command{ .Mode = .{ .target = target, .modes = modes } };
            },
            .kick => {
                const channel = nextToken(&args) orelse return error.MissingArgument;
                const nick = nextToken(&args) orelse return error.MissingArgument;
                const reason = restOrNull(&args);
                return Command{ .Kick = .{ .channel = channel, .nick = nick, .reason = reason } };
            },
            .invite => {
                const nick = nextToken(&args) orelse return error.MissingArgument;
                const channel = nextToken(&args) orelse {
                    if (current_channel) |chan| {
                        if (chan.len == 0) return error.MissingArgument;
                        return Command{ .Invite = .{ .nick = nick, .channel = chan } };
                    }
                    return error.MissingArgument;
                };
                return Command{ .Invite = .{ .nick = nick, .channel = channel } };
            },
            .away => {
                const message = restOrNull(&args);
                return Command{ .Away = message };
            },
            .me => {
                const text = restOrNull(&args) orelse return error.MissingArgument;
                return Command{ .Me = .{ .target = current_channel, .text = text } };
            },
            .help => {
                return Command{ .Help = {} };
            },
        }
    }

    fn nextToken(args: *[]const u8) ?[]const u8 {
        args.* = std.mem.trimStart(u8, args.*, " ");
        if (args.*.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, args.*, ' ') orelse args.*.len;
        const token = args.*[0..end];
        args.* = if (end < args.*.len) args.*[end..] else args.*[end..end];
        return token;
    }

    fn restOrNull(args: *[]const u8) ?[]const u8 {
        args.* = std.mem.trim(u8, args.*, " \r\n\t");
        if (args.*.len == 0) return null;
        return args.*;
    }

    /// Channel names start with one of the RFC 2811 prefixes; anything
    /// else is a nick or free text.
    fn isChannelName(s: []const u8) bool {
        if (s.len == 0) return false;
        return switch (s[0]) {
            '#', '&', '+', '!' => true,
            else => false,
        };
    }
};

test "parse nick/topic/names/whois/me commands" {
    const t = std.testing;
    const cmd_nick = (try Command.parse("/nick alice", null)).?;
    try t.expectEqualStrings("alice", cmd_nick.Nick);

    const cmd_topic_show = (try Command.parse("/topic #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_topic_show.Topic.channel);
    try t.expect(cmd_topic_show.Topic.text == null);

    const cmd_topic_set = (try Command.parse("/topic #zig hello world", null)).?;
    try t.expectEqualStrings("hello world", cmd_topic_set.Topic.text.?);

    const cmd_topic_default = (try Command.parse("/topic", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_topic_default.Topic.channel);

    const cmd_names = (try Command.parse("/names #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_names.Names.?);

    const cmd_names_none = (try Command.parse("/names", null)).?;
    try t.expect(cmd_names_none.Names == null);

    const cmd_whois = (try Command.parse("/whois alice", null)).?;
    try t.expectEqualStrings("alice", cmd_whois.Whois);

    const cmd_me = (try Command.parse("/me waves", "#zig")).?;
    try t.expectEqualStrings("waves", cmd_me.Me.text);
    try t.expectEqualStrings("#zig", cmd_me.Me.target.?);

    try t.expectError(error.MissingArgument, Command.parse("/nick", null));
    try t.expectError(error.MissingArgument, Command.parse("/whois", null));
}

test "parse who/mode/kick/invite/away commands" {
    const t = std.testing;
    const cmd_who = (try Command.parse("/who #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_who.Who);

    const cmd_who_default = (try Command.parse("/who", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_who_default.Who);

    const cmd_mode_show = (try Command.parse("/mode #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_mode_show.Mode.target);
    try t.expect(cmd_mode_show.Mode.modes == null);

    const cmd_mode_set = (try Command.parse("/mode #zig +o alice", null)).?;
    try t.expectEqualStrings("+o alice", cmd_mode_set.Mode.modes.?);

    const cmd_kick = (try Command.parse("/kick #zig bob bye now", null)).?;
    try t.expectEqualStrings("#zig", cmd_kick.Kick.channel);
    try t.expectEqualStrings("bob", cmd_kick.Kick.nick);
    try t.expectEqualStrings("bye now", cmd_kick.Kick.reason.?);

    const cmd_kick_short = (try Command.parse("/k #zig bob", null)).?;
    try t.expect(cmd_kick_short.Kick.reason == null);

    const cmd_invite = (try Command.parse("/invite bob #zig", null)).?;
    try t.expectEqualStrings("bob", cmd_invite.Invite.nick);
    try t.expectEqualStrings("#zig", cmd_invite.Invite.channel);

    const cmd_invite_default = (try Command.parse("/invite bob", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd_invite_default.Invite.channel);

    const cmd_away = (try Command.parse("/away lunch break", null)).?;
    try t.expectEqualStrings("lunch break", cmd_away.Away.?);

    const cmd_back = (try Command.parse("/away", null)).?;
    try t.expect(cmd_back.Away == null);

    try t.expectError(error.MissingArgument, Command.parse("/who", null));
    try t.expectError(error.MissingArgument, Command.parse("/kick #zig", null));
    try t.expectError(error.MissingArgument, Command.parse("/invite", null));
}

test "parse plain text targets the current channel" {
    const t = std.testing;
    const cmd = (try Command.parse("hello there", "#zig")).?;
    try t.expectEqualStrings("#zig", cmd.Msg.target);
    try t.expectEqualStrings("hello there", cmd.Msg.text);
    try t.expectError(error.NoCurrentChannel, Command.parse("hello", null));
    try t.expect(try Command.parse("", "#zig") == null);
    try t.expect((try Command.parse("/reconnect", "#zig")).? == .Reconnect);
    try t.expect((try Command.parse("/reconnect extra", null)).? == .Reconnect);
}

test "parse notice/query/close/cycle commands" {
    const t = std.testing;

    const cmd_notice = (try Command.parse("/notice alice hi there", null)).?;
    try t.expectEqualStrings("alice", cmd_notice.Notice.target);
    try t.expectEqualStrings("hi there", cmd_notice.Notice.text);
    try t.expectError(error.MissingArgument, Command.parse("/notice alice", null));
    try t.expectError(error.MissingArgument, Command.parse("/notice", null));

    const cmd_query = (try Command.parse("/query alice", null)).?;
    try t.expectEqualStrings("alice", cmd_query.Query);
    try t.expectError(error.MissingArgument, Command.parse("/query", null));

    const cmd_close = (try Command.parse("/close", null)).?;
    try t.expect(cmd_close.Close == null);
    const cmd_close_nick = (try Command.parse("/close alice", null)).?;
    try t.expectEqualStrings("alice", cmd_close_nick.Close.?);

    // Bare /cycle defers the channel to execution time.
    const cmd_cycle = (try Command.parse("/cycle", "#zig")).?;
    try t.expect(cmd_cycle.Cycle.channel == null);
    try t.expect(cmd_cycle.Cycle.reason == null);

    const cmd_cycle_chan = (try Command.parse("/cycle #zig", null)).?;
    try t.expectEqualStrings("#zig", cmd_cycle_chan.Cycle.channel.?);
    try t.expect(cmd_cycle_chan.Cycle.reason == null);

    const cmd_cycle_reason = (try Command.parse("/cycle #zig brb now", null)).?;
    try t.expectEqualStrings("#zig", cmd_cycle_reason.Cycle.channel.?);
    try t.expectEqualStrings("brb now", cmd_cycle_reason.Cycle.reason.?);

    // A non-channel word is a reason for the current channel.
    const cmd_cycle_current = (try Command.parse("/cycle brb now", "#zig")).?;
    try t.expect(cmd_cycle_current.Cycle.channel == null);
    try t.expectEqualStrings("brb now", cmd_cycle_current.Cycle.reason.?);

    // Without a current channel the same words name a channel.
    const cmd_cycle_explicit = (try Command.parse("/cycle lobby brb", null)).?;
    try t.expectEqualStrings("lobby", cmd_cycle_explicit.Cycle.channel.?);
    try t.expectEqualStrings("brb", cmd_cycle_explicit.Cycle.reason.?);
}
