//! TCP echo server built on reshift algebraic effects.
//!
//! Demonstrates:
//! - Real network I/O through the effect system
//! - Direct-style code: no async/await, no callbacks
//! - Same handleConnection() code works with blocking OR async handlers
//!
//! Run (blocking, one connection at a time):
//!   zig build run-echo_server
//!
//! Run (async kqueue, concurrent connections):
//!   zig build run-echo_server -- async
//!
//! Test: echo "hello" | nc localhost 8080

const std = @import("std");
const posix = std.posix;
const reshift_io = @import("reshift-io");
const io = reshift_io.io;
const blocking = reshift_io.blocking_runtime;
const kqueue = reshift_io.kqueue_runtime;

const PORT = 8080;

// ── Server logic ─────────────────────────────────────────────
// This is the user code. It uses effects for all I/O.
// It has no idea whether the handler is blocking, kqueue, or io_uring.

var listen_fd: posix.fd_t = undefined;

fn serverLoop() void {
    const print = std.debug.print;

    print("Accepting connections on :{d} ...\n", .{PORT});

    while (true) {
        const result = io.Accept.perform(.{ .listen_fd = listen_fd });

        switch (result) {
            .ok => |conn| {
                print("Connection accepted (fd={d})\n", .{conn.fd});
                handleConnection(conn.fd);
                print("Connection closed  (fd={d})\n", .{conn.fd});
            },
            .err => |e| {
                print("Accept error: {s}\n", .{@tagName(e)});
                return;
            },
        }
    }
}

fn handleConnection(fd: posix.fd_t) void {
    defer io.Close.perform(fd);

    var buf: [4096]u8 = undefined;

    while (true) {
        const read_result = io.Read.perform(.{ .fd = fd, .buffer = &buf });

        switch (read_result) {
            .ok => |n| {
                // Echo back what we received
                var written: usize = 0;
                while (written < n) {
                    const write_result = io.Write.perform(.{
                        .fd = fd,
                        .data = buf[written..n],
                    });
                    switch (write_result) {
                        .ok => |w| written += w,
                        .err => return,
                    }
                }
            },
            .eof => return,
            .err => return,
        }
    }
}

// ── Main: socket setup + handler installation ────────────────

pub fn main() !void {
    const print = std.debug.print;

    // Check for "async" argument
    var args = std.process.args();
    _ = args.next(); // skip program name
    const use_async = if (args.next()) |arg| std.mem.eql(u8, arg, "async") else false;

    // Create TCP listening socket (raw POSIX — setup, not I/O loop)
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PORT);

    listen_fd = posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM,
        0,
    ) catch |err| {
        print("socket() failed: {}\n", .{err});
        return err;
    };
    defer posix.close(listen_fd);

    // Allow port reuse
    posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

    posix.bind(listen_fd, &addr.any, addr.getOsSockLen()) catch |err| {
        print("bind() failed on port {d}: {}\n", .{ PORT, err });
        return err;
    };

    posix.listen(listen_fd, 128) catch |err| {
        print("listen() failed: {}\n", .{err});
        return err;
    };

    print("reshift echo server\n", .{});
    print("Listening on 0.0.0.0:{d}\n", .{PORT});

    if (use_async) {
        print("Mode: async (kqueue, concurrent connections)\n", .{});
        print("Test with: for i in $(seq 1 10); do echo \"hello $i\" | nc localhost {d} & done\n\n", .{PORT});

        // Run with async kqueue event loop.
        // handleConnection is the SAME function — no changes needed.
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        kqueue.runServer(gpa.allocator(), listen_fd, &handleConnection) catch |err| {
            print("Event loop error: {}\n", .{err});
            return err;
        };
    } else {
        print("Mode: blocking (one connection at a time)\n", .{});
        print("Test with: echo \"hello\" | nc localhost {d}\n\n", .{PORT});

        // Run with blocking I/O handlers (tail-resumptive, sequential).
        blocking.runWithIO(void, &serverLoop);
    }
}
