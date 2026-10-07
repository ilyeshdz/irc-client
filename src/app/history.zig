/// Compatibility shim: history now lives in `history/` by responsibility
/// (plain records in `types`, file + JSON log store in `store`).
/// Existing `@import("history.zig")` references keep working.
const types = @import("history/types.zig");
const store = @import("history/store.zig");

pub const Message = types.Message;
pub const Channel = types.Channel;
pub const Server = types.Server;
pub const History = store.History;
pub const historyPath = store.historyPath;

test {
    _ = @import("history/types.zig");
    _ = @import("history/store.zig");
}
