const std = @import("std");

/// The maximum amount of params we can allocate to the memory
const MAX_PARAMS = 15;

pub const Message = struct {
    prefix: ?[]const u8 = null,
    command: []const u8 = "",
    params: [MAX_PARAMS][]const u8 = .{""} ** MAX_PARAMS,
    trailing: []const u8 = "",

    /// Parses a message from a plain string into a `Message` struct.
    pub fn parse(line_in: []const u8) !Message {
        var msg: Message = .{};
        // IRC lines end with CRLF; strip any trailing \r / \n so they don't
        // leak into the trailing parameter.
        const line = std.mem.trimEnd(u8, line_in, "\r\n");
        var cursor: usize = 0;

        if (std.mem.startsWith(u8, line, ":")) {
            if (std.mem.findScalarPos(u8, line, 0, ' ')) |space_idx| {
                msg.prefix = line[1..space_idx];
                cursor = space_idx + 1;
            } else {
                return msg;
            }
        }

        // Skip any extra spaces between prefix and command
        while (cursor < line.len and line[cursor] == ' ') : (cursor += 1) {}

        if (cursor < line.len) {
            if (std.mem.indexOfScalarPos(u8, line, cursor, ' ')) |space_idx| {
                msg.command = line[cursor..space_idx];
                cursor = space_idx + 1;
            } else {
                msg.command = line[cursor..];
                cursor = line.len;
            }
        }

        var params: [MAX_PARAMS][]const u8 = .{""} ** MAX_PARAMS; // allocate and fill that allocated space with [1]const u8
        var params_len: usize = 0;

        var params_slice: []const u8 = undefined;
        if (cursor < line.len and line[cursor] == ':') {
            // Trailing starts immediately after the command, e.g. `PING :server`.
            msg.trailing = line[cursor + 1 ..];
            params_slice = "";
        } else if (std.mem.indexOf(u8, line[cursor..], " :")) |colon_offset| {
            const trailing_start = cursor + colon_offset + 2;
            msg.trailing = line[trailing_start..];
            params_slice = line[cursor .. cursor + colon_offset];
        } else {
            params_slice = line[cursor..];
        }

        var it = std.mem.tokenizeScalar(u8, params_slice, ' ');
        while (it.next()) |param| {
            if (params_len >= params.len) break;
            params[params_len] = param;
            params_len += 1;
        }
        msg.params = params;

        return msg;
    }

    /// Formats the message into a full IRC line, terminated by CRLF.
    pub fn format(self: Message, writer: *std.Io.Writer) !void {
        if (self.command.len == 0) return error.InvalidMessage;
        if (hasCrlf(self.command)) return error.InvalidMessage;
        if (self.prefix) |prefix| {
            if (hasCrlf(prefix)) return error.InvalidMessage;
            try writer.writeAll(":");
            try writer.writeAll(prefix);
            try writer.writeAll(" ");
        }
        try writer.writeAll(self.command);
        for (self.params) |param| {
            if (param.len == 0) continue;
            if (hasCrlf(param)) return error.InvalidMessage;
            try writer.writeAll(" ");
            try writer.writeAll(param);
        }
        if (self.trailing.len > 0) {
            if (hasCrlf(self.trailing)) return error.InvalidMessage;
            try writer.writeAll(" :");
            try writer.writeAll(self.trailing);
        }
        try writer.writeAll("\r\n");
    }

    fn hasCrlf(s: []const u8) bool {
        return std.mem.indexOfScalar(u8, s, '\r') != null or
            std.mem.indexOfScalar(u8, s, '\n') != null;
    }
};
