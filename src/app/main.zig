const std = @import("std");
const Lib = @import("irc-client");
const IrcClient = Lib.IrcClient;
const Cfg = @import("config.zig");
const Picker = @import("picker.zig");
const cli = @import("cli.zig");
const build_options = @import("build_options");
const format = @import("format.zig");
const Display = @import("display.zig").Display;
const History = @import("history.zig").History;
const runEventLoop = @import("input.zig").runEventLoop;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    const opts = cli.parseOrExit(cli.Options, gpa, args);
    defer gpa.free(opts.positional);

    if (opts.options.help) {
        std.debug.print("{s}", .{cli.helpText});
        return;
    }

    if (opts.options.version) {
        std.debug.print("irc_client {s} (zig {s})\n", .{ build_options.version, @import("builtin").zig_version_string });
        return;
    }

    // Profiles live in ~/.config/irc-client/config (best effort: without a
    // HOME we just run without persistence).
    const cfg_path = Cfg.configPath(gpa) catch null;
    defer if (cfg_path) |p| gpa.free(p);
    var cfg = if (cfg_path) |p| Cfg.load(gpa, io, p) catch Cfg.Config.init(gpa) else Cfg.Config.init(gpa);
    defer cfg.deinit();

    var choice: Picker.Choice = undefined;
    var have_choice = false;
    defer if (have_choice) choice.deinit();

    if (opts.options.profile) |name| {
        const p = cfg.findProfile(name) orelse {
            std.debug.print("unknown profile '{s}'.\n", .{name});
            std.process.exit(1);
        };
        choice = .{
            .allocator = gpa,
            .host = try gpa.dupe(u8, p.host),
            .port = p.port,
            .nick = try gpa.dupe(u8, p.nick),
            .realname = try gpa.dupe(u8, p.realname),
            .profile_name = try gpa.dupe(u8, p.name),
        };
        have_choice = true;
    } else if (opts.positional.len > 0) {
        // Quick path for local / host
        const arg_host = opts.positional[0];
        const host = if (std.mem.eql(u8, arg_host, "local")) "127.0.0.1" else arg_host;
        const nick = Picker.defaultNick(&cfg);
        choice = .{
            .allocator = gpa,
            .host = try gpa.dupe(u8, host),
            .port = 6667,
            .nick = try gpa.dupe(u8, nick),
            .realname = try gpa.dupe(u8, nick),
        };
        have_choice = true;
    } else {
        choice = try Picker.pick(&cfg, gpa);
        have_choice = true;
        // Persist right away so a profile created above survives even if
        // the connection below fails.
        if (cfg_path) |p| Cfg.save(&cfg, gpa, io, p) catch {};
    }

    std.debug.print("connecting to {s}:{d} as {s}…\n", .{ choice.host, choice.port, choice.nick });

    // Plain TCP only (no TLS), so 6667-style ports.
    format.setIo(io);
    var client = try IrcClient.init(io, choice.host, choice.port);
    defer client.deinit();

    try client.handshake(choice.nick, choice.realname);

    // Chat history lives in ~/.config/irc-client/history (best effort: a
    // corrupt file just means we start over, like the config does).
    var history = History.load(gpa, io) catch History.init(gpa, io);
    defer history.deinit();

    // The interface layer owns its own display state; seed it with our nick.
    var display = try Display.init(gpa);
    defer display.deinit();
    try display.setCurrentNick(choice.nick);
    try display.setHistory(&history, choice.host);

    cfg.recordUse(choice.host, choice.port, choice.nick, choice.profile_name) catch {};
    if (cfg_path) |p| Cfg.save(&cfg, gpa, io, p) catch {
        std.debug.print("warning: could not save config to {s}\n", .{p});
    };

    try runEventLoop(&client, &display);
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("display.zig");
    _ = @import("history.zig");
    _ = @import("format.zig");
    _ = @import("input.zig");
    _ = @import("inputbox.zig");
    _ = @import("picker.zig");
}
