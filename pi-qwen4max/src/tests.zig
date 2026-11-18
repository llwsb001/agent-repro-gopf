//! Test root: pulls in unit tests (config.zig) and TCP integration tests.

test {
    _ = @import("config.zig");
    _ = @import("integration.zig");
}
