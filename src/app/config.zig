/// Compatibility shim: config now lives in `config/` by responsibility
/// (data model in `types`, file + JSON persistence in `store`).
const types = @import("config/types.zig");
const store = @import("config/store.zig");

pub const common_servers = types.common_servers;
pub const max_recent = types.max_recent;
pub const default_port = types.default_port;
pub const default_tls_port = types.default_tls_port;
pub const Server = types.Server;
pub const RecentEntry = types.RecentEntry;
pub const Profile = types.Profile;
pub const Config = types.Config;
pub const configPath = store.configPath;
pub const load = store.load;
pub const save = store.save;
pub const parseInto = store.parseInto;
pub const serialize = store.serialize;

test {
    _ = @import("config/types.zig");
    _ = @import("config/store.zig");
}
