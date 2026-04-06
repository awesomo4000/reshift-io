//! Blocking I/O runtime — real POSIX syscalls, synchronous.
//!
//! Uses tail-resumptive handlers (tail_fn) for maximum performance:
//! zero context switches, no fibers needed. The blocking syscall IS
//! the handler — perform() calls the syscall inline and returns.
//!
//! This is the simplest possible runtime: one connection at a time,
//! no event loop. Swap in kqueue/io_uring handlers later for concurrency
//! without changing any user code.

const std = @import("std");
const posix = std.posix;
const reshift = @import("reshift");
const Handler = reshift.Handler;
const io = @import("../effects/io.zig");

// ── Tail-resumptive I/O handlers ─────────────────────────────

fn handleRead(req: io.ReadRequest) io.ReadResult {
    const n = posix.read(req.fd, req.buffer) catch |err| {
        return .{ .err = posixError(err) };
    };
    if (n == 0) return .{ .eof = {} };
    return .{ .ok = n };
}

fn handleWrite(req: io.WriteRequest) io.WriteResult {
    const n = posix.write(req.fd, req.data) catch |err| {
        return .{ .err = posixError(err) };
    };
    return .{ .ok = n };
}

fn handleAccept(req: io.AcceptRequest) io.AcceptResult {
    const conn = posix.accept(req.listen_fd, null, null, 0) catch |err| {
        return .{ .err = posixError(err) };
    };
    return .{ .ok = .{ .fd = conn } };
}

fn handleClose(fd: posix.fd_t) void {
    posix.close(fd);
}

/// Extract a posix errno from a Zig error.
fn posixError(err: anyerror) posix.E {
    return switch (err) {
        error.WouldBlock => .AGAIN,
        error.ConnectionResetByPeer => .CONNRESET,
        error.ConnectionRefused => .CONNREFUSED,
        error.BrokenPipe => .PIPE,
        error.NotOpenForReading => .BADF,
        error.InputOutput => .IO,
        error.ConnectionAborted => .CONNABORTED,
        error.SocketNotConnected => .NOTCONN,
        else => .IO,
    };
}

// ── Public API ───────────────────────────────────────────────

/// Run a computation with all blocking I/O handlers installed.
/// The body can freely call io.Read.perform(), io.Write.perform(),
/// io.Accept.perform(), and io.Close.perform().
pub fn runWithIO(comptime Result: type, body: *const fn () Result) Result {
    // Nest handlers: each one wraps the next via thread-local body fn.
    // Because handlers are value types with comptime tail_fn, we construct
    // them inline — no closures needed.
    const Nest = struct {
        // Each layer constructs its handler and runs the next layer as its body.
        // The innermost layer runs the actual user body.

        var user_body: *const fn () Result = undefined;

        fn withClose() Result {
            const h = Handler(io.Close, Result){ .tail_fn = &handleClose };
            return h.run(user_body);
        }

        fn withAccept() Result {
            const h = Handler(io.Accept, Result){ .tail_fn = &handleAccept };
            return h.run(&withClose);
        }

        fn withWrite() Result {
            const h = Handler(io.Write, Result){ .tail_fn = &handleWrite };
            return h.run(&withAccept);
        }

        fn withRead() Result {
            const h = Handler(io.Read, Result){ .tail_fn = &handleRead };
            return h.run(&withWrite);
        }
    };

    Nest.user_body = body;
    return Nest.withRead();
}

/// Individual handler constructors for when you need fine-grained control.
pub fn readHandler(comptime Result: type) Handler(io.Read, Result) {
    return .{ .tail_fn = &handleRead };
}

pub fn writeHandler(comptime Result: type) Handler(io.Write, Result) {
    return .{ .tail_fn = &handleWrite };
}

pub fn acceptHandler(comptime Result: type) Handler(io.Accept, Result) {
    return .{ .tail_fn = &handleAccept };
}

pub fn closeHandler(comptime Result: type) Handler(io.Close, Result) {
    return .{ .tail_fn = &handleClose };
}
