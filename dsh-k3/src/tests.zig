// 测试入口：汇总所有模块的单元测试与集成测试。
test {
    _ = @import("addr.zig");
    _ = @import("config.zig");
    _ = @import("selector.zig");
    _ = @import("proxy.zig");
}
