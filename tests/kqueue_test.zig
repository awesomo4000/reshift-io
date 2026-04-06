//! Tests for the kqueue async event loop.
//!
//! Uses socketpair() so no real network ports are needed.
//! Tests verify that the event loop correctly multiplexes IO
//! across multiple fibers using the effect system.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const reshift_io = @import("reshift-io");
const io = reshift_io.io;
const kqueue = reshift_io.kqueue_runtime;

// ── Helpers ─────────────────────────────────────────────────

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = posix.fcntl(fd, std.c.F.GETFL, 0) catch return error.FcntlFailed;
    _ = posix.fcntl(fd, std.c.F.SETFL, flags | 0x4) catch return error.FcntlFailed;
}

/// Create a non-blocking TCP listening socket on a random ephemeral port.
/// Returns (listen_fd, port).
fn createListener() !struct { fd: posix.fd_t, port: u16 } {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0); // port 0 = OS picks
    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return error.SocketFailed;
    errdefer posix.close(fd);

    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch return error.BindFailed;
    posix.listen(fd, 128) catch return error.ListenFailed;

    // Get the actual port the OS assigned
    var bound_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    posix.getsockname(fd, &bound_addr, &addr_len) catch return error.GetSockNameFailed;
    const port = std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(&bound_addr))).port);

    return .{ .fd = fd, .port = port };
}

/// The echo handler — same one used by the echo server example.
/// Uses effects for all IO, has no idea it's running on kqueue.
fn echoHandler(fd: posix.fd_t) void {
    defer io.Close.perform(fd);

    var buf: [4096]u8 = undefined;
    while (true) {
        const read_result = io.Read.perform(.{ .fd = fd, .buffer = &buf });
        switch (read_result) {
            .ok => |n| {
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

// ── Tests ───────────────────────────────────────────────────

test "kqueue: single connection echo" {
    const listener = try createListener();
    defer posix.close(listener.fd);

    // Start the event loop in a separate thread
    const ServerThread = struct {
        fn run(listen_fd: posix.fd_t) void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            kqueue.runServer(gpa.allocator(), listen_fd, &echoHandler) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{listener.fd});

    // Give server a moment to start
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Connect and send data
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, listener.port);
    const client = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return error.SocketFailed;
    defer posix.close(client);

    posix.connect(client, &addr.any, addr.getOsSockLen()) catch return error.ConnectFailed;

    // Send message
    const msg = "hello kqueue";
    _ = posix.write(client, msg) catch return error.WriteFailed;

    // Shutdown write side to signal EOF
    posix.shutdown(client, .send) catch {};

    // Read echo response
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = posix.read(client, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    try testing.expectEqualStrings(msg, buf[0..total]);

    server_thread.detach();
}

test "kqueue: multiple concurrent connections" {
    const listener = try createListener();
    defer posix.close(listener.fd);

    const ServerThread = struct {
        fn run(listen_fd: posix.fd_t) void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            kqueue.runServer(gpa.allocator(), listen_fd, &echoHandler) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{listener.fd});

    std.Thread.sleep(50 * std.time.ns_per_ms);

    const NUM_CLIENTS = 5;
    var results: [NUM_CLIENTS]bool = [_]bool{false} ** NUM_CLIENTS;

    // Spawn client threads
    var threads: [NUM_CLIENTS]std.Thread = undefined;
    for (0..NUM_CLIENTS) |i| {
        const ClientCtx = struct {
            port: u16,
            index: usize,
            result: *bool,

            fn run(ctx: @This()) void {
                const addr2 = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ctx.port);
                const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
                defer posix.close(sock);
                posix.connect(sock, &addr2.any, addr2.getOsSockLen()) catch return;

                // Send a unique message
                var msg_buf: [32]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "msg-{d}", .{ctx.index}) catch return;
                _ = posix.write(sock, msg) catch return;
                posix.shutdown(sock, .send) catch {};

                // Read echo
                var recv_buf: [4096]u8 = undefined;
                var total: usize = 0;
                while (true) {
                    const n = posix.read(sock, recv_buf[total..]) catch break;
                    if (n == 0) break;
                    total += n;
                }

                if (std.mem.eql(u8, msg, recv_buf[0..total])) {
                    ctx.result.* = true;
                }
            }
        };

        threads[i] = try std.Thread.spawn(.{}, ClientCtx.run, .{ClientCtx{
            .port = listener.port,
            .index = i,
            .result = &results[i],
        }});
    }

    // Wait for all clients
    for (&threads) |*t| {
        t.join();
    }

    // All clients should have gotten their echo
    for (results, 0..) |ok, i| {
        if (!ok) {
            std.debug.print("Client {d} failed to get echo\n", .{i});
        }
        try testing.expect(ok);
    }

    server_thread.detach();
}
