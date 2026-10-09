const std = @import("std");
const fileio = @import("../io.zig");
const types = @import("types.zig");

const Message = types.Message;
const Channel = types.Channel;
const Server = types.Server;

/// Message log at ~/.config/irc-client/history. Every mutation rewrites the
/// whole file, so disk always mirrors memory — at O(history) per message.
pub const History = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
    servers: std.ArrayList(Server) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) History {
        return .{
            .allocator = allocator,
            .io = io,
            .path = historyPath(allocator) catch null,
        };
    }

    /// Same, but persisting to a copy of `path`; null means in-memory only
    /// (no disk writes), which is what tests use.
    pub fn initWithPath(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) History {
        return .{
            .allocator = allocator,
            .io = io,
            .path = if (path) |p| allocator.dupe(u8, p) catch null else null,
        };
    }

    pub fn deinit(self: *History) void {
        self.clearServers();
        if (self.path) |p| self.allocator.free(p);
    }

    /// Reads the history file from the default location. A missing file
    /// simply yields an empty history.
    pub fn load(allocator: std.mem.Allocator, io: std.Io) !History {
        var history = History.init(allocator, io);
        errdefer history.deinit();
        try history.reload();
        return history;
    }

    pub fn reload(self: *History) !void {
        const path = self.path orelse return;
        const bytes = fileio.readFile(self.allocator, self.io, path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(bytes);
        try self.reloadFrom(bytes);
    }

    fn reloadFrom(self: *History, bytes: []const u8) !void {
        if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) {
            self.clearServers();
            return;
        }

        const parsed = std.json.parseFromSlice(SerHistory, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidHistory;
        defer parsed.deinit();

        var servers: std.ArrayList(Server) = .empty;
        errdefer {
            for (servers.items) |*server| server.deinit(self.allocator);
            servers.deinit(self.allocator);
        }

        for (parsed.value.servers) |server| {
            var new_server: Server = .{ .ip = try self.allocator.dupe(u8, server.ip) };
            errdefer new_server.deinit(self.allocator);

            for (server.channels) |channel| {
                var new_channel: Channel = .{ .name = try self.allocator.dupe(u8, channel.name) };
                errdefer new_channel.deinit(self.allocator);

                for (channel.messages) |message| {
                    try new_channel.messages.append(self.allocator, .{
                        .sender = try self.allocator.dupe(u8, message.sender),
                        .timestamp = message.timestamp,
                        .content = try self.allocator.dupe(u8, message.content),
                    });
                }
                try new_server.channels.append(self.allocator, new_channel);
            }
            try servers.append(self.allocator, new_server);
        }

        self.clearServers();
        self.servers = servers;
    }

    /// Writes the whole history to the default path (no-op without one).
    pub fn save(self: *const History) !void {
        const path = self.path orelse return;
        const bytes = try self.serialize();
        defer self.allocator.free(bytes);
        try fileio.writeFile(self.io, path, bytes);
    }

    pub fn addServer(self: *History, server_ip: []const u8) !void {
        _ = try self.getOrCreateServer(server_ip);
        try self.save();
    }

    pub fn addChannel(self: *History, server_ip: []const u8, channel_name: []const u8) !void {
        const server = try self.getOrCreateServer(server_ip);
        _ = try getOrCreateChannel(self.allocator, server, channel_name);
        try self.save();
    }

    pub fn addMessage(
        self: *History,
        server_ip: []const u8,
        channel_name: []const u8,
        message: Message,
    ) !void {
        const server = try self.getOrCreateServer(server_ip);
        const channel = try getOrCreateChannel(self.allocator, server, channel_name);
        try appendMessage(self.allocator, channel, message);
        try self.save();
    }

    fn getOrCreateServer(self: *History, server_ip: []const u8) !*Server {
        for (self.servers.items) |*server| {
            if (std.mem.eql(u8, server.ip, server_ip)) return server;
        }
        const ip = try self.allocator.dupe(u8, server_ip);
        errdefer self.allocator.free(ip);
        try self.servers.append(self.allocator, .{ .ip = ip });
        return &self.servers.items[self.servers.items.len - 1];
    }

    fn getOrCreateChannel(allocator: std.mem.Allocator, server: *Server, channel_name: []const u8) !*Channel {
        for (server.channels.items) |*channel| {
            if (std.mem.eql(u8, channel.name, channel_name)) return channel;
        }
        const name = try allocator.dupe(u8, channel_name);
        errdefer allocator.free(name);
        try server.channels.append(allocator, .{ .name = name });
        return &server.channels.items[server.channels.items.len - 1];
    }

    fn appendMessage(allocator: std.mem.Allocator, channel: *Channel, message: Message) !void {
        const sender = try allocator.dupe(u8, message.sender);
        errdefer allocator.free(sender);
        const content = try allocator.dupe(u8, message.content);
        errdefer allocator.free(content);
        try channel.messages.append(allocator, .{
            .sender = sender,
            .timestamp = message.timestamp,
            .content = content,
        });
    }

    fn clearServers(self: *History) void {
        for (self.servers.items) |*server| {
            server.deinit(self.allocator);
        }
        self.servers.deinit(self.allocator);
        self.servers = .empty;
    }

    fn serialize(self: *const History) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const servers = try aa.alloc(SerServer, self.servers.items.len);
        for (self.servers.items, 0..) |*server, i| {
            const channels = try aa.alloc(SerChannel, server.channels.items.len);
            for (server.channels.items, 0..) |*channel, j| {
                const messages = try aa.alloc(SerMessage, channel.messages.items.len);
                for (channel.messages.items, 0..) |message, k| {
                    messages[k] = .{
                        .sender = message.sender,
                        .timestamp = message.timestamp,
                        .content = message.content,
                    };
                }
                channels[j] = .{ .name = channel.name, .messages = messages };
            }
            servers[i] = .{ .ip = server.ip, .channels = channels };
        }

        return std.json.Stringify.valueAlloc(self.allocator, SerHistory{ .servers = servers }, .{
            .whitespace = .indent_2,
        });
    }
};

pub fn historyPath(allocator: std.mem.Allocator) ![]u8 {
    return fileio.appFilePath(allocator, "history");
}

// --- JSON (de)serialization, tolerant to missing/extra fields ---

const SerMessage = struct {
    sender: []const u8 = "",
    timestamp: i64 = 0,
    content: []const u8 = "",
};

const SerChannel = struct {
    name: []const u8 = "",
    messages: []const SerMessage = &.{},
};

const SerServer = struct {
    ip: []const u8 = "",
    channels: []const SerChannel = &.{},
};

const SerHistory = struct {
    servers: []const SerServer = &.{},
};

test "history roundtrips through json" {
    const t = std.testing;
    var history = History.initWithPath(t.allocator, t.io, null);
    defer history.deinit();

    try history.addServer("irc.libera.chat");
    try history.addChannel("irc.libera.chat", "#zig");
    try history.addMessage("irc.libera.chat", "#zig", Message.init("alice", 1717000000, "hello world"));
    try history.addMessage("irc.libera.chat", "#zig", Message.init("bob", 1717000001, "hi"));
    try history.addMessage("irc.libera.chat", "#rust", Message.init("carol", 1717000002, "cargo"));

    const bytes = try history.serialize();
    defer t.allocator.free(bytes);

    var restored = History.initWithPath(t.allocator, t.io, null);
    defer restored.deinit();
    try restored.reloadFrom(bytes);

    try t.expectEqual(@as(usize, 1), restored.servers.items.len);
    try t.expectEqualStrings("irc.libera.chat", restored.servers.items[0].ip);
    try t.expectEqual(@as(usize, 2), restored.servers.items[0].channels.items.len);

    const zig = restored.servers.items[0].channels.items[0];
    try t.expectEqualStrings("#zig", zig.name);
    try t.expectEqual(@as(usize, 2), zig.messages.items.len);
    try t.expectEqualStrings("alice", zig.messages.items[0].sender);
    try t.expectEqual(@as(i64, 1717000000), zig.messages.items[0].timestamp);
    try t.expectEqualStrings("hello world", zig.messages.items[0].content);
    try t.expectEqualStrings("bob", zig.messages.items[1].sender);

    const rust = restored.servers.items[0].channels.items[1];
    try t.expectEqualStrings("#rust", rust.name);
    try t.expectEqual(@as(usize, 1), rust.messages.items.len);
    try t.expectEqualStrings("cargo", rust.messages.items[0].content);
}

test "addMessage creates server and channel, and dedupes" {
    const t = std.testing;
    var history = History.initWithPath(t.allocator, t.io, null);
    defer history.deinit();

    try history.addMessage("irc.libera.chat", "#zig", Message.init("alice", 1, "one"));
    try history.addMessage("irc.libera.chat", "#zig", Message.init("bob", 2, "two"));
    try history.addMessage("irc.libera.chat", "#rust", Message.init("alice", 3, "three"));
    try history.addMessage("irc.libera.chat", "#zig", Message.init("carol", 4, "four"));

    try t.expectEqual(@as(usize, 1), history.servers.items.len);
    try t.expectEqual(@as(usize, 2), history.servers.items[0].channels.items.len);
    try t.expectEqual(@as(usize, 3), history.servers.items[0].channels.items[0].messages.items.len);
    try t.expectEqual(@as(usize, 1), history.servers.items[0].channels.items[1].messages.items.len);
}

test "missing history file loads as empty history" {
    const t = std.testing;
    var history = History.initWithPath(t.allocator, t.io, "/tmp/irc-client-test-does-not-exist");
    defer history.deinit();
    try history.reload();
    try t.expectEqual(@as(usize, 0), history.servers.items.len);
}

test "history saves to disk and reloads" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(t.io, &dirbuf);
    const file_path = try std.fmt.allocPrint(t.allocator, "{s}/history", .{dirbuf[0..dir_len]});
    defer t.allocator.free(file_path);

    var history = History.initWithPath(t.allocator, t.io, file_path);
    defer history.deinit();
    try history.addMessage("irc.libera.chat", "#zig", Message.init("alice", 1717000000, "persist me"));
    try history.addServer("irc.oftc.net");

    var restored = History.initWithPath(t.allocator, t.io, file_path);
    defer restored.deinit();
    try restored.reload();

    try t.expectEqual(@as(usize, 2), restored.servers.items.len);
    try t.expectEqualStrings("irc.libera.chat", restored.servers.items[0].ip);
    try t.expectEqualStrings("persist me", restored.servers.items[0].channels.items[0].messages.items[0].content);
    try t.expectEqualStrings("irc.oftc.net", restored.servers.items[1].ip);
}
