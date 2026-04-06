//! Deterministic test runtime.
//!
//! Handles all I/O effects with canned responses.
//! No real I/O, no syscalls, fully deterministic.

const std = @import("std");
const io_eff = @import("../effects/io.zig");

pub const TestRuntime = struct {
    /// Canned read responses (FIFO)
    read_responses: std.ArrayList([]const u8) = .{},
    /// Record of all writes
    write_log: std.ArrayList([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestRuntime {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestRuntime) void {
        // Free duped write log entries
        for (self.write_log.items) |entry| {
            self.allocator.free(entry);
        }
        self.read_responses.deinit(self.allocator);
        self.write_log.deinit(self.allocator);
    }

    /// Queue a response that will be returned by the next Read.perform()
    pub fn expectRead(self: *TestRuntime, data: []const u8) !void {
        try self.read_responses.append(self.allocator, data);
    }

    /// Get everything that was written.
    pub fn getWrites(self: *const TestRuntime) []const []const u8 {
        return self.write_log.items;
    }

    // ── Effect handlers ─────────────────────────────

    pub fn handleRead(self: *TestRuntime, req: io_eff.ReadRequest) io_eff.ReadResult {
        if (self.read_responses.items.len == 0) {
            return .{ .eof = {} };
        }
        const data = self.read_responses.orderedRemove(0);
        const copy_len = @min(data.len, req.buffer.len);
        @memcpy(req.buffer[0..copy_len], data[0..copy_len]);
        return .{ .ok = copy_len };
    }

    pub fn handleWrite(self: *TestRuntime, req: io_eff.WriteRequest) io_eff.WriteResult {
        const copy = self.allocator.dupe(u8, req.data) catch return .{ .err = .NOMEM };
        self.write_log.append(self.allocator, copy) catch return .{ .err = .NOMEM };
        return .{ .ok = req.data.len };
    }
};
