/// Compatibility shim: the display now lives in `display/` by domain
/// (state + dispatch in `mod`, handlers in `motd`, `list`, `names`,
/// `events`, `chat`, `topic`, `who`, `status`, shared bits in `util`).
/// Existing `@import("display.zig").Display` references keep working.
pub const Display = @import("display/mod.zig").Display;

test {
    _ = @import("display/mod.zig");
    _ = @import("display/util.zig");
    _ = @import("display/motd.zig");
    _ = @import("display/list.zig");
    _ = @import("display/names.zig");
    _ = @import("display/events.zig");
    _ = @import("display/chat.zig");
    _ = @import("display/topic.zig");
    _ = @import("display/who.zig");
    _ = @import("display/status.zig");
    _ = @import("display/tests.zig");
}
