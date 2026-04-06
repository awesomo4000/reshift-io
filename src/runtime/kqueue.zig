//! kqueue-based async event loop for macOS/BSD.
//!
//! Multiplexes thousands of concurrent connections using the same
//! effect API as the blocking runtime. User code is unchanged —
//! io.Read.perform(), io.Write.perform() etc. just work.
//!
//! Architecture:
//!   - Each connection runs on its own fiber
//!   - Prompts are installed with tail handlers that suspend the fiber
//!   - When a fiber performs IO, the tail handler switches back to the event loop
//!   - The event loop tries non-blocking IO first (fast path)
//!   - If EAGAIN, registers with kqueue and parks the fiber
//!   - When kqueue reports ready, does the syscall and resumes the fiber
//!   - The tail handler returns (perform reads response from EffectChannel)
//!
//! Key insight: tail handlers run on the fiber's stack. They can do a
//! switchContext to suspend back to the event loop, then resume when
//! the event loop switches back. perform() just sees the tail handler
//! return normally with the response in EffectChannel.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const reshift = @import("reshift");
const arch = reshift.arch;
const fiber_mod = reshift.fiber_mod;
const prompt_mod = reshift.prompt;
const effect_mod = reshift.EffectChannel;
const io = @import("../effects/io.zig");

const Fiber = fiber_mod.Fiber;
const Prompt = prompt_mod.Prompt;
const EffectChannel = effect_mod;
const Kevent = std.c.Kevent;

const MAX_EVENTS = 256;
const MAX_FDS = 16384; // max fd number we track

// ── Task: per-connection state ──────────────────────────────

const TaskStatus = enum {
    /// Fiber is actively running (we context-switched to it)
    running,
    /// Fiber yielded an IO effect, waiting for kqueue
    waiting_io,
    /// Fiber completed, ready for cleanup
    done,
};

const PendingOp = enum {
    none,
    read,
    write,
    accept,
};

const Task = struct {
    fiber: Fiber,
    /// 4 prompts for IO effects — all have tail handlers that
    /// suspend back to the event loop via switchContext.
    read_prompt: Prompt,
    write_prompt: Prompt,
    accept_prompt: Prompt,
    close_prompt: Prompt,
    conn_fd: posix.fd_t,
    status: TaskStatus,
    pending_op: PendingOp,
    /// Saved EffectChannel state for this task.
    /// When a task suspends waiting for kqueue, another task may overwrite
    /// the thread-local EffectChannel. We save/restore per-task.
    saved_request: [256]u8 = undefined,
    saved_request_len: usize = 0,
    saved_tag: u64 = 0,
};

// ── Thread-local state for tail handlers ────────────────────
// The tail handlers need to know the current task and event loop
// so they can store pending-op info and switchContext back.

threadlocal var tl_current_loop: ?*EventLoop = null;
threadlocal var tl_current_task: ?*Task = null;

// ── Tail handlers ───────────────────────────────────────────
// These are called by perform() inline on the fiber's stack.
// They store the pending operation, then switchContext back to
// the event loop. When the event loop resumes the fiber,
// execution returns here, and the tail handler returns to
// perform(), which reads the response from EffectChannel.

fn readTailHandler() void {
    const task = tl_current_task.?;
    const loop = tl_current_loop.?;
    task.pending_op = .read;
    task.status = .waiting_io;

    // Suspend: save our position, jump to event loop
    const fiber = fiber_mod.getCurrent().?;
    arch.switchContext(&fiber.regs, &loop.loop_regs);
    // Resumed! Response is now in EffectChannel. Just return.
}

fn writeTailHandler() void {
    const task = tl_current_task.?;
    const loop = tl_current_loop.?;
    task.pending_op = .write;
    task.status = .waiting_io;

    const fiber = fiber_mod.getCurrent().?;
    arch.switchContext(&fiber.regs, &loop.loop_regs);
}

fn acceptTailHandler() void {
    const task = tl_current_task.?;
    const loop = tl_current_loop.?;
    task.pending_op = .accept;
    task.status = .waiting_io;

    const fiber = fiber_mod.getCurrent().?;
    arch.switchContext(&fiber.regs, &loop.loop_regs);
}

fn closeTailHandler() void {
    // Close is synchronous — just do it and return.
    const fd = EffectChannel.getRequest(posix.fd_t);
    posix.close(fd);
    EffectChannel.setResponse(void, {});
}

// ── Event Loop ──────────────────────────────────────────────

pub const EventLoop = struct {
    kq: i32,
    /// Sparse array: fd → task pointer. Indexed by fd number.
    fd_map: [MAX_FDS]?*Task,
    /// All allocated tasks (for cleanup)
    tasks: std.ArrayList(*Task),
    /// kevent result buffer
    event_buf: [MAX_EVENTS]Kevent,
    /// Change list for registering events
    change_buf: [MAX_EVENTS]Kevent,
    change_count: usize,
    allocator: std.mem.Allocator,
    /// Saved registers for the event loop context
    loop_regs: arch.RegisterState,
    /// Number of active (non-done) tasks
    active_count: usize,
    /// The user's connection handler function
    conn_handler: *const fn (posix.fd_t) void,
    /// Listen fd for accept events
    listen_fd: posix.fd_t,

    pub fn init(allocator: std.mem.Allocator, listen_fd: posix.fd_t, handler: *const fn (posix.fd_t) void) !EventLoop {
        const kq = posix.kqueue() catch return error.KqueueFailed;
        var el = EventLoop{
            .kq = kq,
            .fd_map = [_]?*Task{null} ** MAX_FDS,
            .tasks = .{},
            .event_buf = undefined,
            .change_buf = undefined,
            .change_count = 0,
            .allocator = allocator,
            .loop_regs = .{},
            .active_count = 0,
            .conn_handler = handler,
            .listen_fd = listen_fd,
        };

        // Register listen fd for read events (new connections)
        el.addChange(listen_fd, std.c.EVFILT.READ, std.c.EV.ADD, null);

        return el;
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.tasks.items) |task| {
            task.fiber.deinit();
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);
        posix.close(@intCast(self.kq));
    }

    // ── Event registration ──────────────────────────────────

    fn addChange(self: *EventLoop, fd: posix.fd_t, filter: i16, flags: u16, udata: ?*Task) void {
        if (self.change_count >= MAX_EVENTS) {
            self.flushChanges();
        }
        self.change_buf[self.change_count] = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = if (udata) |t| @intFromPtr(t) else 0,
        };
        self.change_count += 1;
    }

    fn flushChanges(self: *EventLoop) void {
        if (self.change_count == 0) return;
        _ = posix.kevent(
            self.kq,
            self.change_buf[0..self.change_count],
            &[0]Kevent{},
            null,
        ) catch {};
        self.change_count = 0;
    }

    // ── Task management ─────────────────────────────────────

    fn spawnTask(self: *EventLoop, conn_fd: posix.fd_t) !void {
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);

        task.* = .{
            .fiber = try Fiber.init(0, &taskTrampoline),
            .read_prompt = makePrompt(io.Read.tag, &task.fiber, &readTailHandler),
            .write_prompt = makePrompt(io.Write.tag, &task.fiber, &writeTailHandler),
            .accept_prompt = makePrompt(io.Accept.tag, &task.fiber, &acceptTailHandler),
            .close_prompt = makePrompt(io.Close.tag, &task.fiber, &closeTailHandler),
            .conn_fd = conn_fd,
            .status = .running,
            .pending_op = .none,
        };

        try self.tasks.append(self.allocator, task);

        // Map fd → task for kqueue event dispatch
        const fd_idx: usize = @intCast(conn_fd);
        if (fd_idx < MAX_FDS) {
            self.fd_map[fd_idx] = task;
        }

        self.active_count += 1;
    }

    fn makePrompt(tag: u64, fiber: *Fiber, tail_handler: prompt_mod.TailHandlerFn) Prompt {
        return .{
            .regs = .{}, // not used — tail handlers switch via fiber.regs/loop_regs
            .stack_pointer = 0,
            .fiber = fiber,
            .parent = null,
            .tag = tag,
            .yield_reason = .none,
            .tail_handler = tail_handler,
        };
    }

    fn cleanupTask(self: *EventLoop, task: *Task) void {
        const fd_idx: usize = @intCast(task.conn_fd);
        if (fd_idx < MAX_FDS) {
            self.fd_map[fd_idx] = null;
        }
        // Remove any kqueue registrations (ignore errors — fd may already be closed)
        self.addChange(task.conn_fd, std.c.EVFILT.READ, std.c.EV.DELETE, null);
        self.addChange(task.conn_fd, std.c.EVFILT.WRITE, std.c.EV.DELETE, null);

        task.fiber.deinit();
        self.active_count -= 1;
    }

    // ── Switch to/from task fiber ───────────────────────────

    /// Switch to a task fiber (first entry or resume).
    /// When the fiber suspends (tail handler switchContext) or completes
    /// (trampoline switchContext), we return here.
    fn switchToFiber(self: *EventLoop, task: *Task) void {
        task.status = .running;
        task.pending_op = .none;

        // Push prompts (outermost first → close, accept, write, read innermost)
        prompt_mod.PromptStack.push(&task.close_prompt);
        prompt_mod.PromptStack.push(&task.accept_prompt);
        prompt_mod.PromptStack.push(&task.write_prompt);
        prompt_mod.PromptStack.push(&task.read_prompt);

        const prev_fiber = fiber_mod.getCurrent();
        fiber_mod.setCurrent(&task.fiber);

        // Set thread-locals for tail handlers and trampoline
        tl_current_loop = self;
        tl_current_task = task;

        // Switch to fiber. Returns when:
        // - A tail handler suspends (switchContext back to loop_regs)
        // - The trampoline completes (switchContext back to loop_regs)
        arch.switchContext(&self.loop_regs, &task.fiber.regs);

        // Pop prompts
        _ = prompt_mod.PromptStack.pop(); // read
        _ = prompt_mod.PromptStack.pop(); // write
        _ = prompt_mod.PromptStack.pop(); // accept
        _ = prompt_mod.PromptStack.pop(); // close

        fiber_mod.setCurrent(prev_fiber);
    }

    // ── IO request handling ─────────────────────────────────
    // After a fiber suspends, check pending_op and try the syscall.

    fn handlePendingIO(self: *EventLoop, task: *Task) void {
        switch (task.pending_op) {
            .read => self.handleRead(task),
            .write => self.handleWrite(task),
            .accept => self.handleAccept(task),
            .none => {},
        }
    }

    /// Save the current EffectChannel request state into the task.
    /// Called when parking a task on kqueue (WouldBlock) so other fibers
    /// can use the shared EffectChannel without clobbering this request.
    fn saveEffectState(task: *Task) void {
        task.saved_tag = EffectChannel.getActiveTag();
        const req_bytes = EffectChannel.getRequestBytes();
        @memcpy(task.saved_request[0..req_bytes.len], req_bytes);
        task.saved_request_len = req_bytes.len;
    }

    /// Restore the EffectChannel request state from the task.
    /// Called before dispatching a kqueue completion so the handler
    /// reads the correct request for this task.
    fn restoreEffectState(task: *Task) void {
        EffectChannel.setRaw(task.saved_tag, task.saved_request[0..task.saved_request_len]);
    }

    fn handleRead(self: *EventLoop, task: *Task) void {
        const req = EffectChannel.getRequest(io.ReadRequest);

        const n = posix.read(req.fd, req.buffer) catch |err| {
            if (err == error.WouldBlock) {
                // Save request state before parking — another fiber may clobber EffectChannel
                saveEffectState(task);
                self.addChange(req.fd, std.c.EVFILT.READ, std.c.EV.ADD | std.c.EV.ONESHOT, task);
                return;
            }
            EffectChannel.setResponse(io.ReadResult, .{ .err = posixError(err) });
            self.resumeFiber(task);
            return;
        };

        if (n == 0) {
            EffectChannel.setResponse(io.ReadResult, .{ .eof = {} });
        } else {
            EffectChannel.setResponse(io.ReadResult, .{ .ok = n });
        }
        self.resumeFiber(task);
    }

    fn handleWrite(self: *EventLoop, task: *Task) void {
        const req = EffectChannel.getRequest(io.WriteRequest);

        const n = posix.write(req.fd, req.data) catch |err| {
            if (err == error.WouldBlock) {
                saveEffectState(task);
                self.addChange(req.fd, std.c.EVFILT.WRITE, std.c.EV.ADD | std.c.EV.ONESHOT, task);
                return;
            }
            EffectChannel.setResponse(io.WriteResult, .{ .err = posixError(err) });
            self.resumeFiber(task);
            return;
        };

        EffectChannel.setResponse(io.WriteResult, .{ .ok = n });
        self.resumeFiber(task);
    }

    fn handleAccept(self: *EventLoop, task: *Task) void {
        const req = EffectChannel.getRequest(io.AcceptRequest);

        const conn = posix.accept(req.listen_fd, null, null, 0) catch |err| {
            if (err == error.WouldBlock) {
                saveEffectState(task);
                self.addChange(req.listen_fd, std.c.EVFILT.READ, std.c.EV.ADD | std.c.EV.ONESHOT, task);
                return;
            }
            EffectChannel.setResponse(io.AcceptResult, .{ .err = posixError(err) });
            self.resumeFiber(task);
            return;
        };

        setNonBlocking(conn) catch {
            posix.close(conn);
            EffectChannel.setResponse(io.AcceptResult, .{ .err = .IO });
            self.resumeFiber(task);
            return;
        };

        EffectChannel.setResponse(io.AcceptResult, .{ .ok = .{ .fd = conn } });
        self.resumeFiber(task);
    }

    /// Resume a fiber that was waiting for IO.
    /// Sets response in EffectChannel BEFORE calling this.
    /// Switches to the fiber — the tail handler resumes and returns,
    /// perform() reads the response, user code continues.
    fn resumeFiber(self: *EventLoop, task: *Task) void {
        self.switchToFiber(task);
        // After returning, check if fiber suspended again or completed
        if (task.status == .done) return;
        if (task.status == .waiting_io) {
            self.handlePendingIO(task);
        }
    }

    // ── Event dispatch (kqueue completion) ──────────────────

    fn dispatchEvent(self: *EventLoop, event: *const Kevent) void {
        const fd: posix.fd_t = @intCast(event.ident);

        // Listen fd — accept new connections
        if (fd == self.listen_fd) {
            self.acceptNewConnection();
            return;
        }

        // Look up which task owns this fd
        const fd_idx: usize = @intCast(fd);
        if (fd_idx >= MAX_FDS) return;
        const task = self.fd_map[fd_idx] orelse return;
        if (task.status != .waiting_io) return;

        // fd is ready — restore this task's EffectChannel state and retry syscall
        restoreEffectState(task);

        switch (task.pending_op) {
            .read => {
                const req = EffectChannel.getRequest(io.ReadRequest);
                const n = posix.read(req.fd, req.buffer) catch |err| {
                    EffectChannel.setResponse(io.ReadResult, .{ .err = posixError(err) });
                    self.resumeFiber(task);
                    return;
                };
                if (n == 0) {
                    EffectChannel.setResponse(io.ReadResult, .{ .eof = {} });
                } else {
                    EffectChannel.setResponse(io.ReadResult, .{ .ok = n });
                }
                self.resumeFiber(task);
            },
            .write => {
                const req = EffectChannel.getRequest(io.WriteRequest);
                const n = posix.write(req.fd, req.data) catch |err| {
                    EffectChannel.setResponse(io.WriteResult, .{ .err = posixError(err) });
                    self.resumeFiber(task);
                    return;
                };
                EffectChannel.setResponse(io.WriteResult, .{ .ok = n });
                self.resumeFiber(task);
            },
            .accept => {
                const req = EffectChannel.getRequest(io.AcceptRequest);
                const conn = posix.accept(req.listen_fd, null, null, 0) catch |err| {
                    EffectChannel.setResponse(io.AcceptResult, .{ .err = posixError(err) });
                    self.resumeFiber(task);
                    return;
                };
                setNonBlocking(conn) catch {
                    posix.close(conn);
                    EffectChannel.setResponse(io.AcceptResult, .{ .err = .IO });
                    self.resumeFiber(task);
                    return;
                };
                EffectChannel.setResponse(io.AcceptResult, .{ .ok = .{ .fd = conn } });
                self.resumeFiber(task);
            },
            .none => {},
        }
    }

    fn acceptNewConnection(self: *EventLoop) void {
        // Accept in a loop (level-triggered may deliver multiple)
        while (true) {
            const conn = posix.accept(self.listen_fd, null, null, 0) catch |err| {
                if (err == error.WouldBlock) return;
                return;
            };

            setNonBlocking(conn) catch {
                posix.close(conn);
                continue;
            };

            self.spawnTask(conn) catch {
                posix.close(conn);
                continue;
            };

            // Run the new task immediately (it will likely suspend on first read)
            const task = self.tasks.items[self.tasks.items.len - 1];
            self.switchToFiber(task);

            // After returning, the task either suspended or completed
            if (task.status == .done) {
                // Fast-path cleanup for connections that complete immediately
                self.cleanupTask(task);
                _ = self.tasks.swapRemove(self.tasks.items.len - 1);
                self.allocator.destroy(task);
            } else if (task.status == .waiting_io) {
                // Try the IO immediately (non-blocking fast path)
                self.handlePendingIO(task);
            }
        }
    }

    // ── Main event loop ─────────────────────────────────────

    pub fn run(self: *EventLoop) !void {
        while (true) {
            // Flush pending kqueue changes and wait for events
            const n = posix.kevent(
                self.kq,
                self.change_buf[0..self.change_count],
                &self.event_buf,
                null, // block until at least one event
            ) catch |err| {
                if (err == error.Interrupted) continue;
                return error.KeventFailed;
            };
            self.change_count = 0;

            // Dispatch each event
            for (self.event_buf[0..n]) |*event| {
                if (event.flags & std.c.EV.ERROR != 0) continue;
                self.dispatchEvent(event);
            }

            // Clean up completed tasks
            var i: usize = 0;
            while (i < self.tasks.items.len) {
                if (self.tasks.items[i].status == .done) {
                    const task = self.tasks.items[i];
                    self.cleanupTask(task);
                    _ = self.tasks.swapRemove(i);
                    self.allocator.destroy(task);
                } else {
                    i += 1;
                }
            }
        }
    }
};

// ── Task trampoline ─────────────────────────────────────────

fn taskTrampoline() callconv(.c) void {
    const task = tl_current_task.?;
    const loop = tl_current_loop.?;

    // Call the user's connection handler
    (loop.conn_handler)(task.conn_fd);

    // Handler returned — mark as done and switch back to event loop
    task.status = .done;
    const fiber = fiber_mod.getCurrent().?;
    fiber.status = .done;
    arch.switchContext(&fiber.regs, &loop.loop_regs);
    unreachable;
}

// ── Utilities ───────────────────────────────────────────────

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = posix.fcntl(fd, std.c.F.GETFL, 0) catch return error.FcntlFailed;
    _ = posix.fcntl(fd, std.c.F.SETFL, flags | 0x4) catch return error.FcntlFailed;
}

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

// ── Public API ──────────────────────────────────────────────

/// Run an async server: accept connections on listen_fd,
/// spawn a fiber per connection running handler(conn_fd).
/// Each fiber can use io.Read.perform(), io.Write.perform() etc.
/// The event loop multiplexes all fibers via kqueue.
pub fn runServer(allocator: std.mem.Allocator, listen_fd: posix.fd_t, handler: *const fn (posix.fd_t) void) !void {
    // Set listen socket to non-blocking
    try setNonBlocking(listen_fd);

    var loop = try EventLoop.init(allocator, listen_fd, handler);
    defer loop.deinit();

    try loop.run();
}
