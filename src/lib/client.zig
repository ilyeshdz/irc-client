/// Compatibility shim: the client now lives in `client/` by domain
/// (lifecycle + wrappers in `mod`, socket/TLS in `conn`, framing in
/// `send`, IRC verbs in `commands`, membership in `state`, reads and
/// PING auto-reply in `read`).
pub const IrcClient = @import("client/mod.zig").IrcClient;

test {
    _ = @import("client/mod.zig");
    _ = @import("client/conn.zig");
    _ = @import("client/send.zig");
    _ = @import("client/commands.zig");
    _ = @import("client/state.zig");
    _ = @import("client/read.zig");
}
