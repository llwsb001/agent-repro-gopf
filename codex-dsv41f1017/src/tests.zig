const std = @import("std");
const gopf = @import("gopf");

test {
    _ = gopf.config;
    _ = gopf.net;
    _ = gopf.proxy;
    _ = @import("integration.zig");
}
