const std = @import("std");

pub const Options = struct {
    help: bool = false,
    profile: ?[]const u8 = null,
};

// Short aliases, keyed by field name of `Options`.
const shorts = .{ .help = 'h', .profile = 'p' };

pub const helpText =
    \\Usage: irc_client [OPTIONS] [HOST]
    \\
    \\Options:
    \\  -h, --help          Display this help message and exit
    \\  -p, --profile NAME  Connect using a saved profile configuration
    \\
    \\Arguments:
    \\  HOST                Hostname or IP address to connect directly (e.g. '127.0.0.1' or 'local')
    \\
    \\If no arguments are provided, an interactive prompt will launch.
    \\
;

pub const ErrorKind = enum { unknown_flag, missing_value, unexpected_value, out_of_memory };

pub const Error = struct {
    kind: ErrorKind,
    // Raw token for `unknown_flag`, field name (without dashes) otherwise.
    flag: []const u8,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        options: T,
        positional: []const []const u8,
    };
}

pub fn Outcome(comptime T: type) type {
    return union(enum) { ok: Parsed(T), err: Error };
}

/// Pure argv parser. Accepted syntax: `--name value`, `--name=value`, `-n value`,
/// and `--` to stop flag parsing. Positionals keep their original order, the last
/// occurrence of a flag wins, and returned strings point into `args` (no copies).
pub fn parse(comptime T: type, gpa: std.mem.Allocator, args: []const [:0]const u8) Outcome(T) {
    var opts: T = .{};
    var positionals: std.ArrayList([]const u8) = .empty;

    const outcome: Outcome(T) = blk: {
        var end_of_flags = false;
        var i: usize = 1; // args[0] is the program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (end_of_flags or arg.len < 2 or arg[0] != '-') {
                positionals.append(gpa, arg) catch break :blk .{ .err = oom() };
                continue;
            }
            if (std.mem.eql(u8, arg, "--")) {
                end_of_flags = true;
                continue;
            }

            const is_long = std.mem.startsWith(u8, arg, "--");
            const body = arg[if (is_long) 2 else 1..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            var matched = false;
            inline for (std.meta.fields(T)) |f| {
                const short: ?u8 = if (@hasField(@TypeOf(shorts), f.name)) @field(shorts, f.name) else null;
                const hit = if (is_long)
                    std.mem.eql(u8, f.name, name)
                else
                    name.len == 1 and short != null and short.? == name[0];
                if (hit) {
                    matched = true;
                    if (@typeInfo(f.type) == .bool) {
                        if (attached != null) break :blk .{ .err = .{ .kind = .unexpected_value, .flag = f.name } };
                        @field(opts, f.name) = true;
                    } else {
                        if (@typeInfo(f.type) != .optional) @compileError("flag field must be bool or ?[]const u8: " ++ f.name);
                        var value: []const u8 = undefined;
                        if (attached) |a| {
                            value = a;
                        } else {
                            if (i + 1 >= args.len or (args[i + 1].len > 1 and args[i + 1][0] == '-'))
                                break :blk .{ .err = .{ .kind = .missing_value, .flag = f.name } };
                            i += 1;
                            value = args[i];
                        }
                        if (value.len == 0) break :blk .{ .err = .{ .kind = .missing_value, .flag = f.name } };
                        @field(opts, f.name) = value;
                    }
                }
            }
            if (!matched) break :blk .{ .err = .{ .kind = .unknown_flag, .flag = arg } };
        }

        const pos = positionals.toOwnedSlice(gpa) catch break :blk .{ .err = oom() };
        break :blk .{ .ok = .{ .options = opts, .positional = pos } };
    };

    switch (outcome) {
        .ok => {},
        .err => positionals.deinit(gpa),
    }
    return outcome;
}

/// Same as `parse`, but reports the error and exits with code 2.
pub fn parseOrExit(comptime T: type, gpa: std.mem.Allocator, args: []const [:0]const u8) Parsed(T) {
    return switch (parse(T, gpa, args)) {
        .ok => |p| p,
        .err => |e| fail(e, if (args.len > 0) args[0] else "irc_client"),
    };
}

pub fn fail(e: Error, prog: []const u8) noreturn {
    printError(e);
    std.debug.print("Run '{s} --help' for usage.\n", .{prog});
    std.process.exit(2);
}

pub fn printError(e: Error) void {
    switch (e.kind) {
        .unknown_flag => std.debug.print("unknown flag '{s}'\n", .{e.flag}),
        .missing_value => std.debug.print("missing value for '--{s}'\n", .{e.flag}),
        .unexpected_value => std.debug.print("option '--{s}' does not take a value\n", .{e.flag}),
        .out_of_memory => std.debug.print("out of memory\n", .{}),
    }
}

fn oom() Error {
    return .{ .kind = .out_of_memory, .flag = "" };
}
