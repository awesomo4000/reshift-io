//! epoll-based event loop handler.
//! Fallback for Linux < 5.1 (no io_uring) and basis for kqueue adapter.
//!
//! TODO: Implement. Structure mirrors iouring.zig but uses epoll_wait.

const std = @import("std");

pub const Runtime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Runtime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn run(_: *Runtime) !void {
        @panic("epoll runtime not yet implemented");
    }
};
