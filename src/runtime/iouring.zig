//! io_uring-based event loop handler for Linux.
//!
//! This is the production runtime. It handles I/O effects by submitting
//! operations to io_uring, suspending the fiber, and resuming when
//! completions arrive.
//!
//! TODO: Implement. This is a stub that will be fleshed out when targeting Linux.

const std = @import("std");

pub const Runtime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Runtime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn run(_: *Runtime) !void {
        @panic("io_uring runtime not yet implemented");
    }
};
