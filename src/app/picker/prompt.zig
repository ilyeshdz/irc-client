const std = @import("std");
const out = @import("../out.zig");
const Cfg = @import("../config.zig");
const entries = @import("entries.zig");

const Choice = entries.Choice;
const Entry = entries.Entry;

/// Interactive startup menu (cooked stdin, before raw mode starts).
/// Prints profiles first (favorites, then rest), then recent servers,
/// then built-in servers, and resolves nick/realname for the pick.
pub fn pick(cfg: *Cfg.Config, allocator: std.mem.Allocator) !Choice {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);

    // Favorites first, then other profiles (last-used profile first).
    var favs: std.ArrayList(*const Cfg.Profile) = .empty;
    defer favs.deinit(allocator);
    var others: std.ArrayList(*const Cfg.Profile) = .empty;
    defer others.deinit(allocator);
    for (cfg.profiles.items) |*p| {
        if (p.favorite) {
            try favs.append(allocator, p);
        } else {
            try others.append(allocator, p);
        }
    }
    if (cfg.last_profile) |last| {
        for (others.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, last)) {
                const moved = others.orderedRemove(i);
                try list.append(allocator, .{ .profile = moved });
                break;
            }
        }
    }
    for (favs.items) |p| try list.append(allocator, .{ .profile = p });
    for (others.items) |p| try list.append(allocator, .{ .profile = p });
    for (cfg.recent.items) |*r| {
        if (r.host.len == 0) continue;
        try list.append(allocator, .{ .recent = r });
    }
    for (Cfg.common_servers) |s| {
        if (alreadyListed(list.items, s.host, s.port, s.tls)) continue;
        try list.append(allocator, .{ .common = s });
    }

    out.print("\n{s}where to?{s}\n", .{ "\x1b[1m", "\x1b[0m" });
    for (list.items, 0..) |e, i| {
        switch (e) {
            .profile => |p| {
                const star = if (p.favorite) " ★" else "";
                const last = if (cfg.last_profile) |l| (if (std.mem.eql(u8, l, p.name)) " [last]" else "") else "";
                out.print("  {d}) {s} — {s} @ {s}{s}{d}{s}{s}\n", .{ i + 1, p.name, p.nick, p.host, if (p.tls) ":+" else ":", p.port, star, last });
            },
            .recent => |r| {
                out.print("  {d}) {s}{s}{d} (recent{s}{s})\n", .{ i + 1, r.host, if (r.tls) ":+" else ":", r.port, if (r.nick.len > 0) ", nick " else "", r.nick });
            },
            .common => |s| {
                out.print("  {d}) {s}{s}{d}\n", .{ i + 1, s.host, if (s.tls) ":+" else ":", s.port });
            },
        }
    }
    out.print("  n) new connection…\n", .{});
    out.print("choice [1]: ", .{});

    const raw_choice = try readLine(allocator);
    defer allocator.free(raw_choice);
    const trimmed = std.mem.trim(u8, raw_choice, " \r\n\t");

    if (trimmed.len == 0) {
        if (list.items.len > 0) return resolveEntry(cfg, allocator, list.items[0]);
        return resolveNew(cfg, allocator);
    }
    if (trimmed.len == 1 and (trimmed[0] == 'n' or trimmed[0] == 'N')) {
        return resolveNew(cfg, allocator);
    }
    const n = std.fmt.parseInt(usize, trimmed, 10) catch {
        out.print("invalid choice, starting over with defaults.\n", .{});
        return resolveEntry(cfg, allocator, list.items[0]);
    };
    if (n == 0 or n > list.items.len) {
        out.print("out of range, starting over with defaults.\n", .{});
        return resolveEntry(cfg, allocator, list.items[0]);
    }
    return resolveEntry(cfg, allocator, list.items[n - 1]);
}

fn alreadyListed(list: []const Entry, host: []const u8, port: u16, tls: bool) bool {
    for (list) |e| {
        switch (e) {
            .profile => |p| {
                if (p.tls == tls and p.port == port and std.mem.eql(u8, p.host, host)) return true;
            },
            .recent => |r| {
                if (r.tls == tls and r.port == port and std.mem.eql(u8, r.host, host)) return true;
            },
            .common => {},
        }
    }
    return false;
}

fn resolveEntry(cfg: *Cfg.Config, allocator: std.mem.Allocator, entry: Entry) !Choice {
    switch (entry) {
        .profile => |p| {
            return .{
                .allocator = allocator,
                .host = try allocator.dupe(u8, p.host),
                .port = p.port,
                .tls = p.tls,
                .nick = try allocator.dupe(u8, p.nick),
                .realname = try allocator.dupe(u8, p.realname),
                .profile_name = try allocator.dupe(u8, p.name),
            };
        },
        .recent => |r| {
            const nick = if (r.nick.len > 0) r.nick else entries.defaultNick(cfg);
            const picked_nick = try ask(allocator, "nick", nick);
            const realname = try ask(allocator, "realname", picked_nick);
            return .{
                .allocator = allocator,
                .host = try allocator.dupe(u8, r.host),
                .port = r.port,
                .tls = r.tls,
                .nick = picked_nick,
                .realname = realname,
            };
        },
        .common => |s| {
            const picked_nick = try ask(allocator, "nick", entries.defaultNick(cfg));
            const realname = try ask(allocator, "realname", picked_nick);
            return .{
                .allocator = allocator,
                .host = try allocator.dupe(u8, s.host),
                .port = s.port,
                .tls = s.tls,
                .nick = picked_nick,
                .realname = realname,
            };
        },
    }
}

fn askTls(allocator: std.mem.Allocator, default: bool) !bool {
    const raw = try ask(allocator, "tls", if (default) "y" else "n");
    defer allocator.free(raw);
    const t = std.mem.trim(u8, raw, " \r\n\t");
    if (t.len == 0) return default;
    return t[0] == 'y' or t[0] == 'Y';
}

fn resolveNew(cfg: *Cfg.Config, allocator: std.mem.Allocator) !Choice {
    const raw_host = try ask(allocator, "server", Cfg.common_servers[0].host);
    defer allocator.free(raw_host);
    const split = entries.splitHostPort(std.mem.trim(u8, raw_host, " \r\n\t"));
    const host = try allocator.dupe(u8, if (split.host.len > 0) split.host else Cfg.common_servers[0].host);
    errdefer allocator.free(host);
    const tls_default = split.tls orelse false;
    const tls = if (split.tls != null) tls_default else try askTls(allocator, false);
    const default_port = if (tls) Cfg.default_tls_port else Cfg.default_port;
    var port: u16 = split.port orelse default_port;
    if (split.port == null) {
        var default_buf: [8]u8 = undefined;
        const default_str = std.fmt.bufPrint(&default_buf, "{d}", .{default_port}) catch std.fmt.comptimePrint("{d}", .{Cfg.default_port});
        const port_str = try ask(allocator, "port", default_str);
        defer allocator.free(port_str);
        port = std.fmt.parseInt(u16, std.mem.trim(u8, port_str, " "), 10) catch default_port;
    }
    const nick = try ask(allocator, "nick", entries.defaultNick(cfg));
    const realname = try ask(allocator, "realname", nick);

    var choice = Choice{
        .allocator = allocator,
        .host = host,
        .port = port,
        .tls = tls,
        .nick = nick,
        .realname = realname,
    };
    const name = try ask(allocator, "save as profile (empty to skip)", "");
    defer allocator.free(name);
    if (name.len > 0) {
        const profile = Cfg.Profile{
            .name = try allocator.dupe(u8, name),
            .nick = try allocator.dupe(u8, choice.nick),
            .realname = try allocator.dupe(u8, choice.realname),
            .host = try allocator.dupe(u8, choice.host),
            .port = choice.port,
            .tls = choice.tls,
            .favorite = false,
        };
        try cfg.upsertProfile(profile);
        choice.profile_name = try allocator.dupe(u8, name);
        out.print("saved profile '{s}'.\n", .{name});
    }
    return choice;
}

/// Prompt for a value on cooked stdin; empty input keeps `default`.
/// Returns an owned string.
pub fn ask(allocator: std.mem.Allocator, prompt: []const u8, default: []const u8) ![]u8 {
    out.print("{s} [{s}]: ", .{ prompt, default });
    const raw = try readLine(allocator);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return allocator.dupe(u8, default);
    return allocator.dupe(u8, trimmed);
}

fn readLine(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    // One byte at a time: a single read() may return several lines, and any
    // bytes past the first '\n' belong to the *next* prompt, so they must
    // not be swallowed here (piped input arrives all at once).
    var one: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &one);
        if (n == 0) break; // EOF
        if (one[0] == '\n') break;
        try buf.append(allocator, one[0]);
    }
    return buf.toOwnedSlice(allocator);
}
