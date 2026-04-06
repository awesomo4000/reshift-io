//! reshift-io — I/O Runtime for reshift
//!
//! Provides I/O effect definitions (Read, Write, Accept, Close, Sleep, Spawn,
//! Join, Log) and runtime implementations (blocking, kqueue, epoll, io_uring,
//! testing) built on reshift's algebraic effect primitives.
//!
//! For the core effect system, see the reshift package.

pub const io = @import("effects/io.zig");
pub const builtins = @import("effects/builtins.zig");

pub const blocking_runtime = @import("runtime/blocking.zig");
pub const kqueue_runtime = @import("runtime/kqueue.zig");
pub const testing_runtime = @import("runtime/testing.zig");
pub const epoll_runtime = @import("runtime/epoll.zig");
pub const iouring_runtime = @import("runtime/iouring.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
