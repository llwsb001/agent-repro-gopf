pub const config = @import("config.zig");
pub const net = @import("net.zig");
pub const proxy = @import("proxy.zig");

test {
    _ = config;
    _ = net;
    _ = proxy;
}
