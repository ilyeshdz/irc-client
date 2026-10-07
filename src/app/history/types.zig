const std = @import("std");

pub const Message = struct {
    sender: []const u8,
    timestamp: i64,
    content: []const u8,

    pub fn init(sender: []const u8, timestamp: i64, content: []const u8) Message {
        return .{
            .sender = sender,
            .timestamp = timestamp,
            .content = content,
        };
    }
};

pub const Channel = struct {
    name: []const u8,
    messages: std.ArrayList(Message) = .empty,

    pub fn deinit(self: *Channel, alloc: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            alloc.free(message.sender);
            alloc.free(message.content);
        }
        self.messages.deinit(alloc);
        alloc.free(self.name);
    }
};

pub const Server = struct {
    ip: []const u8,
    channels: std.ArrayList(Channel) = .empty,

    pub fn deinit(self: *Server, alloc: std.mem.Allocator) void {
        for (self.channels.items) |*channel| {
            channel.deinit(alloc);
        }
        self.channels.deinit(alloc);
        alloc.free(self.ip);
    }
};
