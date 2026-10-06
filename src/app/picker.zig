const std = @import("std");
const out = @import("out.zig");
const Cfg = @import("config.zig");

/// A resolved connection choice. All strings are owned; call deinit.
pub const Choice = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls: bool = false,
    insecure: bool = false,
    nick: []const u8,
    realname: []const u8,
    profile_name: ?[]const u8 = null,

    pub fn deinit(self: *Choice) void {
        self.allocator.free(self.host);
        self.allocator.free(self.nick);
        self.allocator.free(self.realname);
        if (self.profile_name) |n| self.allocator.free(n);
    }

    pub fn describe(self: *const Choice, buf: []u8) ![]u8 {
        if (self.tls) {
            return std.fmt.bufPrint(buf, "{s}:+{d}", .{ self.host, self.port });
        }
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port });
    }
};

const Entry = union(enum) {
    profile: *const Cfg.Profile,
    common: Cfg.Server,
    recent: *const Cfg.RecentEntry,
};

/// Interactive startup menu (cooked stdin, before raw mode starts).
/// Prints profiles first (favorites, then rest), then recent servers,
/// then built-in servers, and resolves nick/realname for the pick.
pub fn pick(cfg: *Cfg.Config, allocator: std.mem.Allocator) !Choice {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

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
                try entries.append(allocator, .{ .profile = moved });
                break;
            }
        }
    }
    for (favs.items) |p| try entries.append(allocator, .{ .profile = p });
    for (others.items) |p| try entries.append(allocator, .{ .profile = p });
    for (cfg.recent.items) |*r| {
        if (r.host.len == 0) continue;
        try entries.append(allocator, .{ .recent = r });
    }
    for (Cfg.common_servers) |s| {
        if (alreadyListed(entries.items, s.host, s.port, s.tls)) continue;
        try entries.append(allocator, .{ .common = s });
    }

    out.print("\n{s}where to?{s}\n", .{ "\x1b[1m", "\x1b[0m" });
    for (entries.items, 0..) |e, i| {
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
        if (entries.items.len > 0) return resolveEntry(cfg, allocator, entries.items[0]);
        return resolveNew(cfg, allocator);
    }
    if (trimmed.len == 1 and (trimmed[0] == 'n' or trimmed[0] == 'N')) {
        return resolveNew(cfg, allocator);
    }
    const n = std.fmt.parseInt(usize, trimmed, 10) catch {
        out.print("invalid choice, starting over with defaults.\n", .{});
        return resolveEntry(cfg, allocator, entries.items[0]);
    };
    if (n == 0 or n > entries.items.len) {
        out.print("out of range, starting over with defaults.\n", .{});
        return resolveEntry(cfg, allocator, entries.items[0]);
    }
    return resolveEntry(cfg, allocator, entries.items[n - 1]);
}

fn alreadyListed(entries: []const Entry, host: []const u8, port: u16, tls: bool) bool {
    for (entries) |e| {
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
            const nick = if (r.nick.len > 0) r.nick else defaultNick(cfg);
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
            const picked_nick = try ask(allocator, "nick", defaultNick(cfg));
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

/// Split `host[:[+]port]` (e.g. `irc.libera.chat:+6697`) into its parts.
/// Returns host, optional port, and whether `+` requested TLS.
pub fn splitHostPort(raw: []const u8) struct { host: []const u8, port: ?u16, tls: ?bool } {
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return .{ .host = raw, .port = null, .tls = null };
    // An IPv6 literal like `[::1]:6697` keeps the brackets on the host.
    const host_part = raw[0..colon];
    const port_part = raw[colon + 1 ..];
    if (port_part.len == 0) return .{ .host = host_part, .port = null, .tls = null };
    if (port_part[0] == '+') {
        const port = std.fmt.parseInt(u16, port_part[1..], 10) catch return .{ .host = raw, .port = null, .tls = null };
        return .{ .host = host_part, .port = port, .tls = true };
    }
    const port = std.fmt.parseInt(u16, port_part, 10) catch return .{ .host = raw, .port = null, .tls = null };
    return .{ .host = host_part, .port = port, .tls = null };
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
    const split = splitHostPort(std.mem.trim(u8, raw_host, " \r\n\t"));
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
    const nick = try ask(allocator, "nick", defaultNick(cfg));
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

pub fn defaultNick(cfg: *const Cfg.Config) []const u8 {
    if (cfg.last_profile) |last| {
        if (cfg.findProfile(last)) |p| return p.nick;
    }
    if (cfg.recent.items.len > 0 and cfg.recent.items[0].nick.len > 0) {
        return cfg.recent.items[0].nick;
    }
    return "guest";
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

test "host:port and host:+port parsing" {
    const t = std.testing;
    const a = splitHostPort("irc.libera.chat");
    try t.expectEqualStrings("irc.libera.chat", a.host);
    try t.expect(a.port == null and a.tls == null);

    const b = splitHostPort("irc.libera.chat:6667");
    try t.expectEqualStrings("irc.libera.chat", b.host);
    try t.expectEqual(@as(u16, 6667), b.port.?);
    try t.expect(b.tls == null);

    const c = splitHostPort("irc.libera.chat:+6697");
    try t.expectEqualStrings("irc.libera.chat", c.host);
    try t.expectEqual(@as(u16, 6697), c.port.?);
    try t.expectEqual(true, c.tls.?);

    const d = splitHostPort("127.0.0.1:+6697");
    try t.expectEqualStrings("127.0.0.1", d.host);
    try t.expect(d.tls.?);

    // Non-numeric ports are left as a bare hostname.
    const e = splitHostPort("example.com:notaport");
    try t.expectEqualStrings("example.com:notaport", e.host);
    try t.expect(e.port == null);
}
