const std = @import("std");
const fileio = @import("io.zig");

/// Built-in servers suggested when no profile matches. Maybe change that later
pub const common_servers = [_]Server{
    .{ .host = "irc.ircnet.com", .port = default_port },
    .{ .host = "irc.libera.chat", .port = default_port },
    .{ .host = "irc.oftc.net", .port = default_port },
    .{ .host = "127.0.0.1", .port = default_port },
};

pub const max_recent: usize = 5;

/// Plain TCP fallback when no port is configured anywhere.
pub const default_port: u16 = 6667;

pub const Server = struct {
    host: []const u8,
    port: u16 = default_port,
};

pub const RecentEntry = struct {
    host: []const u8,
    port: u16 = default_port,
    nick: []const u8 = "",

    fn deinit(self: *RecentEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.nick);
    }
};

pub const Profile = struct {
    name: []const u8,
    nick: []const u8,
    realname: []const u8,
    host: []const u8,
    port: u16 = default_port,
    favorite: bool = false,

    fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.nick);
        allocator.free(self.realname);
        allocator.free(self.host);
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(Profile),
    recent: std.ArrayList(RecentEntry),
    last_profile: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .profiles = .empty,
            .recent = .empty,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.profiles.items) |*p| p.deinit(self.allocator);
        self.profiles.deinit(self.allocator);
        for (self.recent.items) |*r| r.deinit(self.allocator);
        self.recent.deinit(self.allocator);
        if (self.last_profile) |l| self.allocator.free(l);
    }

    pub fn findProfile(self: *const Config, name: []const u8) ?*const Profile {
        for (self.profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn upsertProfile(self: *Config, profile: Profile) !void {
        for (self.profiles.items) |*p| {
            if (!std.mem.eql(u8, p.name, profile.name)) continue;
            p.deinit(self.allocator);
            p.* = profile;
            return;
        }
        try self.profiles.append(self.allocator, profile);
    }

    /// Record a connection in the recent list (most recent first, capped).
    /// Also remembers the profile name used, if any.
    pub fn recordUse(self: *Config, host: []const u8, port: u16, nick: []const u8, profile_name: ?[]const u8) !void {
        var kept: std.ArrayList(RecentEntry) = .empty;
        defer kept.deinit(self.allocator);
        try kept.append(self.allocator, .{
            .host = try self.allocator.dupe(u8, host),
            .port = port,
            .nick = try self.allocator.dupe(u8, nick),
        });
        for (self.recent.items) |*r| {
            if (kept.items.len >= max_recent) {
                r.deinit(self.allocator);
                continue;
            }
            if (std.mem.eql(u8, r.host, host) and r.port == port) {
                r.deinit(self.allocator);
                continue;
            }
            try kept.append(self.allocator, r.*);
        }
        self.recent.clearRetainingCapacity();
        try self.recent.appendSlice(self.allocator, kept.items);

        if (self.last_profile) |l| self.allocator.free(l);
        self.last_profile = if (profile_name) |n| try self.allocator.dupe(u8, n) else null;
    }
};

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    return fileio.appFilePath(allocator, "config");
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();
    const bytes = fileio.readFile(allocator, io, path) catch |err| {
        if (err == error.FileNotFound) return cfg;
        return err;
    };
    defer allocator.free(bytes);
    try parseInto(&cfg, bytes);
    return cfg;
}

pub fn save(cfg: *const Config, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try serialize(allocator, cfg);
    defer allocator.free(bytes);
    try fileio.writeFile(io, path, bytes);
}

// --- JSON (de)serialization, tolerant to missing/extra fields ---

fn getStr(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .string => |s| s,
        else => default,
    };
}

fn getPort(obj: std.json.ObjectMap) u16 {
    const v = obj.get("port") orelse return default_port;
    return switch (v) {
        .integer => |n| std.math.cast(u16, n) orelse default_port,
        else => default_port,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

pub fn parseInto(cfg: *Config, bytes: []const u8) !void {
    const allocator = cfg.allocator;
    // JSON values own arena memory; our dupes keep the main allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var scanner = std.json.Scanner.initCompleteInput(aa, bytes);
    defer scanner.deinit();
    const value = std.json.Value.jsonParse(aa, &scanner, .{ .max_value_len = bytes.len }) catch return error.InvalidConfig;
    const root = switch (value) {
        .object => |*o| o,
        else => return error.InvalidConfig,
    };

    if (root.get("profiles")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                try cfg.profiles.append(allocator, .{
                    .name = try allocator.dupe(u8, getStr(o, "name", "default")),
                    .nick = try allocator.dupe(u8, getStr(o, "nick", "guest")),
                    .realname = try allocator.dupe(u8, getStr(o, "realname", getStr(o, "nick", "guest"))),
                    .host = try allocator.dupe(u8, getStr(o, "host", "irc.ircnet.com")),
                    .port = getPort(o),
                    .favorite = getBool(o, "favorite"),
                });
            }
        }
    }
    if (root.get("recent")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |item| {
                if (item != .object) continue;
                if (cfg.recent.items.len >= max_recent) break;
                const o = item.object;
                try cfg.recent.append(allocator, .{
                    .host = try allocator.dupe(u8, getStr(o, "host", "")),
                    .port = getPort(o),
                    .nick = try allocator.dupe(u8, getStr(o, "nick", "")),
                });
            }
        }
    }
    if (root.get("last_profile")) |lv| {
        if (lv == .string and lv.string.len > 0) {
            if (cfg.last_profile) |l| allocator.free(l);
            cfg.last_profile = try allocator.dupe(u8, lv.string);
        }
    }
}

const SerProfile = struct {
    name: []const u8,
    nick: []const u8,
    realname: []const u8,
    host: []const u8,
    port: u16,
    favorite: bool,
};

const SerRecent = struct {
    host: []const u8,
    port: u16,
    nick: []const u8,
};

const SerConfig = struct {
    profiles: []const SerProfile,
    recent: []const SerRecent,
    last_profile: ?[]const u8,
};

pub fn serialize(allocator: std.mem.Allocator, cfg: *const Config) ![]u8 {
    const profiles = try allocator.alloc(SerProfile, cfg.profiles.items.len);
    defer allocator.free(profiles);
    for (cfg.profiles.items, 0..) |*p, i| {
        profiles[i] = .{
            .name = p.name,
            .nick = p.nick,
            .realname = p.realname,
            .host = p.host,
            .port = p.port,
            .favorite = p.favorite,
        };
    }
    const recent = try allocator.alloc(SerRecent, cfg.recent.items.len);
    defer allocator.free(recent);
    for (cfg.recent.items, 0..) |*r, i| {
        recent[i] = .{ .host = r.host, .port = r.port, .nick = r.nick };
    }
    const doc = SerConfig{ .profiles = profiles, .recent = recent, .last_profile = cfg.last_profile };
    return std.json.Stringify.valueAlloc(allocator, doc, .{ .whitespace = .indent_2 });
}

test "config roundtrips through json" {
    const t = std.testing;
    var cfg = Config.init(t.allocator);
    defer cfg.deinit();
    try cfg.profiles.append(t.allocator, .{
        .name = try t.allocator.dupe(u8, "home"),
        .nick = try t.allocator.dupe(u8, "hdz"),
        .realname = try t.allocator.dupe(u8, "ilyes"),
        .host = try t.allocator.dupe(u8, "irc.libera.chat"),
        .port = 6667,
        .favorite = true,
    });
    try cfg.recordUse("irc.libera.chat", 6667, "hdz", "home");

    const bytes = try serialize(t.allocator, &cfg);
    defer t.allocator.free(bytes);

    var cfg2 = Config.init(t.allocator);
    defer cfg2.deinit();
    try parseInto(&cfg2, bytes);
    try t.expectEqual(@as(usize, 1), cfg2.profiles.items.len);
    try t.expectEqualStrings("home", cfg2.profiles.items[0].name);
    try t.expectEqualStrings("hdz", cfg2.profiles.items[0].nick);
    try t.expect(cfg2.profiles.items[0].favorite);
    try t.expectEqual(@as(usize, 1), cfg2.recent.items.len);
    try t.expectEqualStrings("home", cfg2.last_profile.?);
}

test "missing file fields fall back to defaults" {
    const t = std.testing;
    var cfg = Config.init(t.allocator);
    defer cfg.deinit();
    try parseInto(&cfg, "{\"profiles\": [{\"name\": \"x\"}]}");
    try t.expectEqualStrings("guest", cfg.profiles.items[0].nick);
    try t.expectEqualStrings("irc.ircnet.com", cfg.profiles.items[0].host);
    try t.expectEqual(@as(u16, 6667), cfg.profiles.items[0].port);
}

test "recent list caps and dedupes" {
    const t = std.testing;
    var cfg = Config.init(t.allocator);
    defer cfg.deinit();
    var i: u8 = 0;
    while (i < 7) : (i += 1) {
        var host_buf: [16]u8 = undefined;
        const host = try std.fmt.bufPrint(&host_buf, "srv{d}.test", .{i});
        try cfg.recordUse(host, 6667, "n", null);
    }
    try t.expectEqual(max_recent, cfg.recent.items.len);
    try t.expectEqualStrings("srv6.test", cfg.recent.items[0].host);
    try cfg.recordUse("srv6.test", 6667, "n", null);
    try t.expectEqual(max_recent, cfg.recent.items.len);
    try t.expectEqualStrings("srv6.test", cfg.recent.items[0].host);
}
