//! Integration test: run server code with the test handler.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const reshift_io = @import("reshift-io");
const io = reshift_io.io;
const blocking = reshift_io.blocking_runtime;

test "test runtime handles read/write" {
    var rt = reshift_io.testing_runtime.TestRuntime.init(testing.allocator);
    defer rt.deinit();

    // Queue a fake read response
    try rt.expectRead("GET / HTTP/1.1\r\n\r\n");

    // Simulate reading
    var buf: [1024]u8 = undefined;
    const result = rt.handleRead(.{ .fd = 0, .buffer = &buf });

    switch (result) {
        .ok => |n| {
            try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", buf[0..n]);
        },
        else => return error.UnexpectedResult,
    }

    // Simulate writing
    const write_result = rt.handleWrite(.{ .fd = 1, .data = "HTTP/1.1 200 OK\r\n\r\n" });
    switch (write_result) {
        .ok => |n| try testing.expectEqual(@as(usize, 19), n),
        else => return error.UnexpectedResult,
    }

    // Verify writes were recorded
    const writes = rt.getWrites();
    try testing.expectEqual(@as(usize, 1), writes.len);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\n", writes[0]);
}

test "test runtime returns eof when no reads queued" {
    var rt = reshift_io.testing_runtime.TestRuntime.init(testing.allocator);
    defer rt.deinit();

    var buf: [1024]u8 = undefined;
    const result = rt.handleRead(.{ .fd = 0, .buffer = &buf });

    switch (result) {
        .eof => {},
        else => return error.ExpectedEof,
    }
}

test "test runtime records multiple writes" {
    var rt = reshift_io.testing_runtime.TestRuntime.init(testing.allocator);
    defer rt.deinit();

    _ = rt.handleWrite(.{ .fd = 1, .data = "hello" });
    _ = rt.handleWrite(.{ .fd = 1, .data = "world" });

    const writes = rt.getWrites();
    try testing.expectEqual(@as(usize, 2), writes.len);
    try testing.expectEqualStrings("hello", writes[0]);
    try testing.expectEqualStrings("world", writes[1]);
}

test "blocking runtime handles read and write" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const Body = struct {
        var read_fd: posix.fd_t = undefined;
        var write_fd: posix.fd_t = undefined;

        fn run() usize {
            switch (io.Write.perform(.{ .fd = write_fd, .data = "hi" })) {
                .ok => {},
                .err => return 0,
            }

            var buf: [8]u8 = undefined;
            return switch (io.Read.perform(.{ .fd = read_fd, .buffer = &buf })) {
                .ok => |n| if (std.mem.eql(u8, buf[0..n], "hi")) n else 0,
                .eof => 0,
                .err => 0,
            };
        }
    };

    Body.read_fd = pipe_fds[0];
    Body.write_fd = pipe_fds[1];

    const result = blocking.runWithIO(usize, &Body.run);
    try testing.expectEqual(@as(usize, 2), result);
}
