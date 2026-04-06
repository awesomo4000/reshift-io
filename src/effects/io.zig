//! I/O effect definitions.
//!
//! These define WHAT I/O operations are available.
//! HOW they're executed depends on the handler (io_uring, epoll, mock, etc.)

const std = @import("std");
const reshift = @import("reshift");
const Effect = reshift.Effect;

/// Read bytes from a file descriptor.
pub const Read = Effect("io.Read", ReadRequest, ReadResult);

pub const ReadRequest = struct {
    fd: std.posix.fd_t,
    buffer: []u8,
    offset: ?u64 = null,
};

pub const ReadResult = union(enum) {
    ok: usize,
    eof: void,
    err: std.posix.E,
};

/// Write bytes to a file descriptor.
pub const Write = Effect("io.Write", WriteRequest, WriteResult);

pub const WriteRequest = struct {
    fd: std.posix.fd_t,
    data: []const u8,
    offset: ?u64 = null,
};

pub const WriteResult = union(enum) {
    ok: usize,
    err: std.posix.E,
};

/// Accept a connection on a listening socket.
pub const Accept = Effect("io.Accept", AcceptRequest, AcceptResult);

pub const AcceptRequest = struct {
    listen_fd: std.posix.fd_t,
};

pub const AcceptResult = union(enum) {
    ok: struct {
        fd: std.posix.fd_t,
    },
    err: std.posix.E,
};

/// Close a file descriptor.
pub const Close = Effect("io.Close", std.posix.fd_t, void);
