const std = @import("std");

/// Built-in servers suggested when no profile matches.
pub const common_servers = [_]Server{
    .{ .host = "irc.ircnet.com", .port = default_port },
    .{ .host = "irc.libera.chat", .port = default_port },
    .{ .host = "irc.oftc.net", .port = default_port },
    .{ .host = "127.0.0.1", .port = default_port },
};

pub const max_recent: usize = 5;

/// Plain TCP fallback when no port is configured anywhere.
pub const default_port: u16 = 6667;

/// Default port for TLS connections.
pub const default_tls_port: u16 = 6697;

pub const Server = struct {
    host: []const u8,
    port: u16 = default_port,
    tls: bool = false,
};

pub const RecentEntry = struct {
    host: []const u8,
    port: u16 = default_port,
    tls: bool = false,
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
    tls: bool = false,
    favorite: bool = false,
    /// Channels joined automatically after (re)connect. Managed by
    /// editing `channels` in the config file; empty by default.
    channels: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.nick);
        allocator.free(self.realname);
        allocator.free(self.host);
        for (self.channels.items) |c| allocator.free(c);
        self.channels.deinit(allocator);
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
        return self.recordUseTls(host, port, false, nick, profile_name);
    }

    /// Same as `recordUse`, but remembers whether the connection used TLS.
    pub fn recordUseTls(self: *Config, host: []const u8, port: u16, tls: bool, nick: []const u8, profile_name: ?[]const u8) !void {
        var kept: std.ArrayList(RecentEntry) = .empty;
        defer kept.deinit(self.allocator);
        try kept.append(self.allocator, .{
            .host = try self.allocator.dupe(u8, host),
            .port = port,
            .tls = tls,
            .nick = try self.allocator.dupe(u8, nick),
        });
        for (self.recent.items) |*r| {
            if (kept.items.len >= max_recent) {
                r.deinit(self.allocator);
                continue;
            }
            if (std.mem.eql(u8, r.host, host) and r.port == port and r.tls == tls) {
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
