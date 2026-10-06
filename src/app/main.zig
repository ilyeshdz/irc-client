const std = @import("std");
const out = @import("out.zig");
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
        out.print("{s}", .{cli.helpText});
        return;
    }

    if (opts.options.version) {
        out.print("irc_client {s} (zig {s})\n", .{ build_options.version, @import("builtin").zig_version_string });
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
            out.print("unknown profile '{s}'\n", .{name});
            std.process.exit(1);
        };
        var port = p.port;
        if (opts.options.port) |port_str| {
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                out.print("invalid port '{s}'\n", .{port_str});
                std.process.exit(1);
            };
        }
        choice = .{
            .allocator = gpa,
            .host = try gpa.dupe(u8, p.host),
            .port = port,
            .tls = p.tls or opts.options.tls,
            .insecure = opts.options.insecure,
            .nick = try gpa.dupe(u8, p.nick),
            .realname = try gpa.dupe(u8, p.realname),
            .profile_name = try gpa.dupe(u8, p.name),
        };
        have_choice = true;
    } else if (opts.positional.len > 0) {
        // Quick path: `local`, `host`, `host:port`, or `host:+port`
        // (`+` forces TLS). Flags still apply: --port overrides the
        // port, --tls/--insecure force those modes on.
        const arg_host = opts.positional[0];
        const mapped = if (std.mem.eql(u8, arg_host, "local")) "127.0.0.1" else arg_host;
        const split = Picker.splitHostPort(mapped);
        const tls = (split.tls orelse false) or opts.options.tls;
        var port: u16 = undefined;
        if (opts.options.port) |port_str| {
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                out.print("invalid port '{s}'\n", .{port_str});
                std.process.exit(1);
            };
        } else if (split.port) |sp| {
            port = sp;
        } else {
            port = if (tls) Cfg.default_tls_port else Cfg.default_port;
        }
        const host = if (std.mem.eql(u8, split.host, "local")) "127.0.0.1" else split.host;
        const nick = Picker.defaultNick(&cfg);
        choice = .{
            .allocator = gpa,
            .host = try gpa.dupe(u8, host),
            .port = port,
            .tls = tls,
            .insecure = opts.options.insecure,
            .nick = try gpa.dupe(u8, nick),
            .realname = try gpa.dupe(u8, nick),
        };
        have_choice = true;
    } else {
        choice = try Picker.pick(&cfg, gpa);
        // Non-interactive flags still force the mode on for picker results.
        if (opts.options.tls) choice.tls = true;
        if (opts.options.insecure) choice.insecure = true;
        if (opts.options.port) |port_str| {
            choice.port = std.fmt.parseInt(u16, port_str, 10) catch {
                out.print("invalid port '{s}'\n", .{port_str});
                std.process.exit(1);
            };
        }
        have_choice = true;
        // Persist right away so a profile created above survives even if
        // the connection below fails.
        if (cfg_path) |p| Cfg.save(&cfg, gpa, io, p) catch {};
    }

    if (choice.tls) {
        out.print("connecting to {s}:+{d} (TLS) as {s}…\n", .{ choice.host, choice.port, choice.nick });
    } else {
        out.print("connecting to {s}:{d} as {s}…\n", .{ choice.host, choice.port, choice.nick });
    }

    format.setIo(io);
    var client = IrcClient.initOptions(io, choice.host, choice.port, .{
        .tls = choice.tls,
        .insecure = choice.insecure,
    }) catch |err| {
        reportConnectError(err, &choice);
        std.process.exit(1);
    };
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

    cfg.recordUseTls(choice.host, choice.port, choice.tls, choice.nick, choice.profile_name) catch {};
    if (cfg_path) |p| Cfg.save(&cfg, gpa, io, p) catch {
        out.print("warning: could not save config to {s}\n", .{p});
    };

    try runEventLoop(&client, &display);
}

fn reportConnectError(err: anyerror, choice: *const Picker.Choice) void {
    out.print("could not connect to {s}:{d}: {s}\n", .{ choice.host, choice.port, @errorName(err) });
    if (choice.tls) {
        out.print("TLS handshake failed. If this server uses a self-signed certificate (e.g. local ergo), retry with --insecure. If it is plaintext-only, retry without --tls.\n", .{});
    } else {
        out.print("If the server requires TLS, retry with --tls (default TLS port is {d}, e.g. {s}:+{d}).\n", .{ Cfg.default_tls_port, choice.host, Cfg.default_tls_port });
    }
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
