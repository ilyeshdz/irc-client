const std = @import("std");
const out = @import("out.zig");
const fmt = @import("format.zig");

pub const Options = struct {
    help: bool = false,
    version: bool = false,
    profile: ?[]const u8 = null,

    pub const TAGS = .{
        .help = .{ .desc = "Display this help message and exit", .short = "h" },
        .version = .{ .desc = "Display version information and exit", .short = "V" },
        .profile = .{ .desc = "Connect using a saved profile configuration", .short = "p" },
    };
};

/// ` <value>` for options that consume one, nothing for bare flags.
fn valueSuffix(comptime takes_value: bool) []const u8 {
    return if (takes_value) " <value>" else "";
}

fn optionWidth(comptime o: type) usize {
    var w: usize = 0;
    inline for (@typeInfo(o).@"struct".fields) |field| {
        const takes_value = @typeInfo(field.type) == .optional;
        w = @max(w, ("--" ++ field.name ++ comptime valueSuffix(takes_value)).len);
    }
    return w;
}

fn descWidth(comptime o: type) usize {
    var w: usize = 0;
    inline for (@typeInfo(o).@"struct".fields) |field| {
        w = @max(w, @field(o.TAGS, field.name).desc.len);
    }
    return w;
}

/// Build the whole --help text as one string: the column widths are derived
/// from the option list at comptime, so entries never carry manual padding —
/// add an option and the grid reflows.
pub fn generateHelpText(comptime o: type) []const u8 {
    const ow = @max(optionWidth(o), "OPTION".len);
    const dw = @max(descWidth(o), "DESCRIPTION".len);

    var text: []const u8 = "Usage: irc_client [OPTIONS]\n\nOptions:\n";
    text = text ++ "  " ++ fmt.pad("OPTION", ow) ++ "  " ++
        fmt.pad("DESCRIPTION", dw) ++ "  SHORT\n";
    inline for (@typeInfo(o).@"struct".fields) |field| {
        const tag = @field(o.TAGS, field.name);
        const takes_value = @typeInfo(field.type) == .optional;
        const name_part: []const u8 = "--" ++ field.name;
        const value_part = comptime valueSuffix(takes_value);
        const alias: []const u8 = "-" ++ tag.short;
        text = text ++ "  " ++ name_part ++ value_part ++
            fmt.spaces(ow - name_part.len - value_part.len) ++ "  " ++
            tag.desc ++ fmt.spaces(dw - tag.desc.len) ++ "  " ++
            alias ++ "\n";
    }
    return text;
}

// Short aliases, keyed by field name of `Options`.
const shorts = .{ .help = 'h', .version = 'V', .profile = 'p' };

pub const helpText = generateHelpText(Options);

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
    out.print("Run '{s} --help' for usage.\n", .{prog});
    std.process.exit(2);
}

pub fn printError(e: Error) void {
    switch (e.kind) {
        .unknown_flag => out.print("unknown flag '{s}'\n", .{e.flag}),
        .missing_value => out.print("missing value for '--{s}'\n", .{e.flag}),
        .unexpected_value => out.print("option '--{s}' does not take a value\n", .{e.flag}),
        .out_of_memory => out.print("out of memory\n", .{}),
    }
}

fn oom() Error {
    return .{ .kind = .out_of_memory, .flag = "" };
}

test "every option starts its columns on the same byte" {
    const t = std.testing;
    // The --help text is plain: no escapes, just the grid.
    try t.expect(std.mem.indexOf(u8, helpText, "\x1b[") == null);

    const ow = @max(optionWidth(Options), "OPTION".len);
    const dw = @max(descWidth(Options), "DESCRIPTION".len);
    const desc_at = 2 + ow + 2;
    const alias_at = desc_at + dw + 2;

    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, helpText, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  --")) continue;
        // The description starts right after two spaces, and the short
        // alias sits at a fixed column after it.
        try t.expect(line.len > alias_at);
        try t.expectEqual(@as(u8, ' '), line[desc_at - 1]);
        try t.expect(line[desc_at] != ' ');
        try t.expectEqual(@as(u8, '-'), line[alias_at]);
        try t.expect(line.len <= 80);
        rows += 1;
    }
    try t.expectEqual(@typeInfo(Options).@"struct".fields.len, rows);
}
