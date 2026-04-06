//! kqueue echo server throughput benchmark.
//!
//! Measures how many echo round-trips per second the async server can handle.
//! Uses multiple client threads to saturate the server.
//!
//! Run: zig build run-kqueue_bench -Doptimize=ReleaseFast

const std = @import("std");
const posix = std.posix;
const reshift_io = @import("reshift-io");
const io = reshift_io.io;
const kqueue = reshift_io.kqueue_runtime;

// ── Configuration ───────────────────────────────────────────

const NUM_CLIENTS = 50;
const MESSAGES_PER_CLIENT = 10_000;
const MSG = "hello reshift kqueue echo!\n";
const PORT = 0; // ephemeral

// ── Echo handler (identical to the example) ─────────────────

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

// ── Server thread ───────────────────────────────────────────

fn serverThread(listen_fd: posix.fd_t) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    kqueue.runServer(gpa.allocator(), listen_fd, &echoHandler) catch {};
}

// ── Client thread ───────────────────────────────────────────

const ClientResult = struct {
    messages_sent: u64,
    messages_received: u64,
    bytes_sent: u64,
    bytes_received: u64,
    errors: u64,
    elapsed_ns: u64,
};

fn clientThread(port: u16, result: *ClientResult) void {
    result.* = .{
        .messages_sent = 0,
        .messages_received = 0,
        .bytes_sent = 0,
        .bytes_received = 0,
        .errors = 0,
        .elapsed_ns = 0,
    };

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
        result.errors = 1;
        return;
    };
    defer posix.close(sock);

    // Disable Nagle for low-latency round trips
    posix.setsockopt(sock, posix.IPPROTO.TCP, std.c.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
        result.errors = 1;
        return;
    };

    var timer = std.time.Timer.start() catch {
        result.errors = 1;
        return;
    };

    var recv_buf: [4096]u8 = undefined;

    for (0..MESSAGES_PER_CLIENT) |_| {
        // Send
        var sent: usize = 0;
        while (sent < MSG.len) {
            const n = posix.write(sock, MSG[sent..]) catch {
                result.errors += 1;
                break;
            };
            sent += n;
        }
        if (sent < MSG.len) break;
        result.messages_sent += 1;
        result.bytes_sent += sent;

        // Receive echo
        var received: usize = 0;
        while (received < MSG.len) {
            const n = posix.read(sock, recv_buf[0..]) catch {
                result.errors += 1;
                break;
            };
            if (n == 0) break;
            received += n;
        }
        if (received >= MSG.len) {
            result.messages_received += 1;
            result.bytes_received += received;
        } else {
            result.errors += 1;
            break;
        }
    }

    result.elapsed_ns = timer.read();
}

// ── Main ────────────────────────────────────────────────────

pub fn main() !void {
    const print = std.debug.print;

    print("═══════════════════════════════════════════════════════\n", .{});
    print("  reshift kqueue echo server benchmark\n", .{});
    print("═══════════════════════════════════════════════════════\n\n", .{});
    print("  Clients:            {d}\n", .{NUM_CLIENTS});
    print("  Messages/client:    {d}\n", .{MESSAGES_PER_CLIENT});
    print("  Message size:       {d} bytes\n", .{MSG.len});
    print("  Total messages:     {d}\n\n", .{@as(u64, NUM_CLIENTS) * MESSAGES_PER_CLIENT});

    // Create listener on ephemeral port
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, PORT);
    const listen_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return error.SocketFailed;
    defer posix.close(listen_fd);

    posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.bind(listen_fd, &addr.any, addr.getOsSockLen()) catch return error.BindFailed;
    posix.listen(listen_fd, 256) catch return error.ListenFailed;

    // Get the actual port
    var bound_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    posix.getsockname(listen_fd, &bound_addr, &addr_len) catch return error.GetSockNameFailed;
    const port = std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(&bound_addr))).port);

    print("  Server port:        {d}\n", .{port});
    print("  Starting server...\n", .{});

    // Start server
    const server = try std.Thread.spawn(.{}, serverThread, .{listen_fd});
    _ = server;

    // Let server settle
    std.Thread.sleep(50 * std.time.ns_per_ms);

    print("  Launching {d} client threads...\n\n", .{NUM_CLIENTS});

    // Start all clients
    var threads: [NUM_CLIENTS]std.Thread = undefined;
    var results: [NUM_CLIENTS]ClientResult = undefined;

    var overall_timer = std.time.Timer.start() catch return error.TimerFailed;

    for (0..NUM_CLIENTS) |i| {
        threads[i] = std.Thread.spawn(.{}, clientThread, .{ port, &results[i] }) catch return error.ThreadSpawnFailed;
    }

    // Wait for all clients
    for (0..NUM_CLIENTS) |i| {
        threads[i].join();
    }

    const wall_ns = overall_timer.read();
    const wall_s = @as(f64, @floatFromInt(wall_ns)) / 1e9;

    // Aggregate results
    var total_sent: u64 = 0;
    var total_received: u64 = 0;
    var total_bytes_sent: u64 = 0;
    var total_bytes_received: u64 = 0;
    var total_errors: u64 = 0;
    var max_client_ns: u64 = 0;
    var min_client_ns: u64 = std.math.maxInt(u64);

    for (&results) |*r| {
        total_sent += r.messages_sent;
        total_received += r.messages_received;
        total_bytes_sent += r.bytes_sent;
        total_bytes_received += r.bytes_received;
        total_errors += r.errors;
        if (r.elapsed_ns > max_client_ns) max_client_ns = r.elapsed_ns;
        if (r.elapsed_ns < min_client_ns and r.elapsed_ns > 0) min_client_ns = r.elapsed_ns;
    }

    const msg_per_sec = @as(f64, @floatFromInt(total_received)) / wall_s;
    const mb_per_sec = @as(f64, @floatFromInt(total_bytes_received + total_bytes_sent)) / wall_s / (1024.0 * 1024.0);
    const avg_latency_us = if (total_received > 0)
        @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(total_received)) / 1000.0 * @as(f64, NUM_CLIENTS)
    else
        0.0;

    print("─── Results ───────────────────────────────────────────\n\n", .{});
    print("  Wall clock:         {d:.3}s\n", .{wall_s});
    print("  Messages sent:      {d}\n", .{total_sent});
    print("  Messages received:  {d}\n", .{total_received});
    print("  Errors:             {d}\n\n", .{total_errors});

    print("  Throughput:         {d:.0} msg/sec\n", .{msg_per_sec});
    print("  Bandwidth:          {d:.1} MB/sec\n", .{mb_per_sec});
    print("  Avg round-trip:     {d:.1} us\n\n", .{avg_latency_us});

    print("  Fastest client:     {d:.3}s\n", .{@as(f64, @floatFromInt(min_client_ns)) / 1e9});
    print("  Slowest client:     {d:.3}s\n", .{@as(f64, @floatFromInt(max_client_ns)) / 1e9});

    print("\n═══════════════════════════════════════════════════════\n", .{});

    // Get RSS
    const rusage = posix.getrusage(0);
    const rss_kb: usize = @intCast(rusage.maxrss);
    const rss_mb = if (@import("builtin").os.tag == .macos) rss_kb / 1024 / 1024 else rss_kb / 1024;
    print("  Peak RSS:           {d} MB\n", .{rss_mb});
    print("═══════════════════════════════════════════════════════\n", .{});
}
