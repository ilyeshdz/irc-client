const std = @import("std");
const Lib = @import("irc-client");
const IrcClient = Lib.IrcClient;
const runEventLoop = Lib.runEventLoop;
const Cfg = Lib.Config;
const Picker = Lib.Picker;

const helpMessage =
    \\Usage: irc_client [OPTIONS] [HOST]
    \\
    \\Options:
    \\  --help            Display this help message and exit
    \\  --profile NAME    Connect using a saved profile configuration
    \\
    \\Arguments:
    \\  HOST              Hostname or IP address to connect directly (e.g. '127.0.0.1' or 'local')
    \\
    \\If no arguments are provided, an interactive prompt will launch.
    \\
;

// TODO: Replace it later / move it somewhere else
pub fn findStringWithinSliceOfString(slice: []const []const u8, target: []const u8) bool {
    for (slice) |item| {
        if (std.mem.eql(u8, item, target)) {
            return true;
        }
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (findStringWithinSliceOfString(args, "--help")) {
        std.debug.print(helpMessage, .{});
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

    if (Lib.getValueForOption(args, "profile", true)) |val| {
        const p = cfg.findProfile(val) orelse {
            std.debug.print("unknown profile '{s}'.\n", .{args[2]});
            return;
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
    }

    // Quick path for lcoal / host
    if (args.len == 2) {
        const arg_host = args[1];
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
    var client = try IrcClient.init(io, choice.host, choice.port);
    defer client.deinit();

    try client.handshake(choice.nick, choice.realname);

    cfg.recordUse(choice.host, choice.port, choice.nick, choice.profile_name) catch {};
    if (cfg_path) |p| Cfg.save(&cfg, gpa, io, p) catch {
        std.debug.print("warning: could not save config to {s}\n", .{p});
    };

    try runEventLoop(&client);
}
