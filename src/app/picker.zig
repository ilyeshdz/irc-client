/// Compatibility shim: picker now lives in `picker/` by responsibility
/// (pure entries + parsing in `entries`, interactive prompts in `prompt`).
/// Existing `@import("picker.zig")` references keep working.
const entries = @import("picker/entries.zig");
const prompt = @import("picker/prompt.zig");

pub const Choice = entries.Choice;
pub const Entry = entries.Entry;
pub const splitHostPort = entries.splitHostPort;
pub const defaultNick = entries.defaultNick;
pub const pick = prompt.pick;
pub const ask = prompt.ask;

test {
    _ = @import("picker/entries.zig");
    _ = @import("picker/prompt.zig");
}
