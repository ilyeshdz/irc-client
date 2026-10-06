const std = @import("std");

/// Path to a file under ~/.config/irc-client (best effort: without a HOME
/// the caller runs without persistence).
pub fn appFilePath(allocator: std.mem.Allocator, leaf: []const u8) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/irc-client/{s}", .{ std.mem.span(home), leaf });
}

/// Read a whole file into an owned slice. A missing file surfaces as
/// error.FileNotFound so callers can fall back to defaults.
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        return err;
    };
    defer std.Io.File.close(f, io);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    var reader = f.reader(io, &buf);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&tmp);
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Write bytes to path, creating parent directories as needed.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    }
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer std.Io.File.close(f, io);
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
