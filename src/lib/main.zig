pub const IrcClient = @import("client.zig").IrcClient;
pub const Message = @import("message.zig").Message;

test {
    _ = @import("client.zig");
    _ = @import("message.zig");
}
