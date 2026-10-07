const std = @import("std");
const Cfg = @import("../config.zig");

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

pub const Entry = union(enum) {
    profile: *const Cfg.Profile,
    common: Cfg.Server,
    recent: *const Cfg.RecentEntry,
};

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

pub fn defaultNick(cfg: *const Cfg.Config) []const u8 {
    if (cfg.last_profile) |last| {
        if (cfg.findProfile(last)) |p| return p.nick;
    }
    if (cfg.recent.items.len > 0 and cfg.recent.items[0].nick.len > 0) {
        return cfg.recent.items[0].nick;
    }
    return "guest";
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
