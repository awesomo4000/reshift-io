# Runtime Architecture Design

This document describes the architecture for reshift's multi-threaded async runtime. It captures the design decisions, threading model, and API surface for future implementation.

## Current State

reshift has a working single-threaded kqueue event loop (`src/runtime/kqueue.zig`) that multiplexes thousands of fibers. The effect system is inherently thread-safe — EffectChannel, PromptStack, and handler thread-locals are all per-thread. Multiple threads can independently run handlers/fibers with zero coordination today.

The same user code works with blocking, async, and test runtimes without modification. This is the core value proposition and must be preserved.

## Threading Model: Thread-per-Loop, No Fiber Migration

Each worker thread owns its own kqueue event loop, fiber pool, and thread-local state. Connections are assigned to a worker at accept time and never migrate. This is what Nginx, HAProxy, and Go effectively do for I/O-bound workloads.

**Why not fiber migration?** Fibers carry implicit state through three thread-local channels: EffectChannel, PromptStack, and handler thread-locals. Migrating all of this is possible (we already save/restore EffectChannel per-task in kqueue.zig) but the PromptStack save/restore adds complexity, and the payoff is marginal for network servers where connections produce roughly uniform work.

**Why not multi-process?** Loses shared in-process state (caches, connection pools, coordinated backpressure). Also, macOS `SO_REUSEPORT` doesn't load-balance like Linux.

```
                    ┌─────────────────────────────┐
                    │       Acceptor Thread        │
                    │   accept() → distribute      │
                    └──────────────┬───────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                     ▼
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │  Worker Thread 0  │ │  Worker Thread 1  │ │  Worker Thread N  │
   │                   │ │                   │ │                   │
   │  kqueue loop      │ │  kqueue loop      │ │  kqueue loop      │
   │  fiber scheduler  │ │  fiber scheduler  │ │  fiber scheduler  │
   │  EffectChannel    │ │  EffectChannel    │ │  EffectChannel    │
   │  PromptStack      │ │  PromptStack      │ │  PromptStack      │
   │  FiberPool        │ │  FiberPool        │ │  FiberPool        │
   │  StackCache       │ │  StackCache       │ │  StackCache       │
   └──────────────────┘ └──────────────────┘ └──────────────────┘
              │                    │                     │
              └────────────────────┼────────────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │    CPU Offload Thread Pool    │
                    │   (bounded, for compute work) │
                    └──────────────────────────────┘
```

## Components

### Worker

Each worker thread owns everything it needs. No sharing, no locks on the hot path.

```zig
pub const Worker = struct {
    id: u16,
    loop: EventLoop,            // per-thread kqueue
    ready_queue: FiberQueue,    // fibers ready to run
    inbox: SpscQueue(NewConn),  // new fds from acceptor (lock-free)
    fiber_pool: FiberPool,
    active_fibers: Atomic(u32), // for load-aware distribution
    wakeup: WakeupFd,          // EVFILT_USER (kqueue) / eventfd (Linux)

    pub fn run(self: *Worker) void {
        while (!shutdown) {
            self.drainInbox();      // register new connections
            self.runReadyFibers();  // run until they block on I/O
            const events = self.loop.poll(self.nextTimeout());
            for (events) |ev| {
                self.ready_queue.push(ev.fiber);
            }
        }
    }
};
```

### Acceptor

One thread accepts connections and distributes to workers via lock-free SPSC queues.

```zig
pub const Acceptor = struct {
    listen_fd: fd_t,
    workers: []Worker,
    strategy: enum { round_robin, least_loaded },

    pub fn run(self: *Acceptor) void {
        while (!shutdown) {
            const client_fd = posix.accept(self.listen_fd, ...);
            const worker = self.pickWorker();
            worker.inbox.push(.{ .fd = client_fd });
            worker.wakeup.notify();
        }
    }
};
```

Round-robin is simplest and works well when connections have similar lifetimes. Least-loaded reads each worker's `active_fibers` atomic counter — no locks, just relaxed loads.

### CPU Offload Pool

For compute-heavy work that would block a worker's event loop. Exposed as an effect:

```zig
const Offload = Effect("Offload", OffloadRequest, OffloadResult);

// User code — looks like a normal call
const compressed = Offload.perform(.{ .func = zlib.compress, .data = raw });
```

The handler packages the work, sends it to a bounded thread pool, suspends the fiber, and resumes it when the pool thread completes. Same mechanism as kqueue I/O — the fiber doesn't know it left the event loop thread.

### Runtime (Public API)

```zig
pub const Runtime = struct {
    workers: []Worker,
    acceptor: Acceptor,
    offload: OffloadPool,

    pub fn init(allocator: Allocator, opts: Options) !Runtime { ... }
    pub fn deinit(self: *Runtime) void { ... }

    /// Run a server: accept connections, run handler on fibers
    pub fn serve(self: *Runtime, handler: *const fn(fd_t) void) !void { ... }

    /// Spawn a task on a worker thread (for non-server use)
    pub fn spawn(self: *Runtime, func: *const fn() void) TaskHandle { ... }

    pub const Options = struct {
        threads: u16 = 0,               // 0 = auto (CPU count - 1)
        listen_addr: ?Address = null,
        distribution: enum { round_robin, least_loaded } = .round_robin,
        max_connections: u32 = 10_000,
        offload_threads: u16 = 4,
    };
};
```

**User code is unchanged.** The same `handleConnection` function that works with `blocking.runWithIO` and `kqueue.runServer` works here. Only the top-level wiring changes.

## Result Types and Railway-Oriented Programming

### Result(T, E)

Formalize the tagged union pattern already used by IO effects:

```zig
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        /// Transform the success value. Errors pass through.
        pub fn map(self, f: fn(T) U) Result(U, E) { ... }

        /// Chain operations that can fail (flatMap / andThen / bind).
        pub fn andThen(self, f: fn(T) Result(U, E)) Result(U, E) { ... }

        /// Transform the error value.
        pub fn mapErr(self, f: fn(E) F) Result(T, F) { ... }

        /// Unwrap with default.
        pub fn unwrapOr(self, default: T) T { ... }
    };
}
```

### Comptime Pipeline Composition

Type-checked at compile time, zero runtime overhead (inline for loop):

```zig
const HttpPipeline = Pipeline(&.{
    stage("parse",     parseRequest),     // []u8 → Result(Request, ParseError)
    stage("validate",  validateRequest),  // Request → Result(Request, ValidationError)
    stage("handle",    handleRequest),    // Request → Result(Response, AppError)
    stage("serialize", serializeResp),    // Response → Result([]u8, SerializeError)
});

// Usage:
const result = HttpPipeline.run(raw_bytes);
switch (result) {
    .ok => |bytes| _ = io.Write.perform(.{ .fd = fd, .data = bytes }),
    .err => |e| writeError(fd, e),
}
```

Each stage is a normal function that can call `Effect.perform()` internally. The pipeline doesn't know or care about effects — it just chains return values. Effects are orthogonal to the data flow.

Type mismatches between pipeline stages are caught at compile time with clear error messages.

### Error-as-Effect Pattern

For code that wants to throw without restructuring control flow:

```zig
const Throw = Effect("Throw", anyerror, noreturn);

// The body just signals the error
fn riskyOperation() i32 {
    if (somethingWrong()) Throw.perform(error.BadInput);
    return 42;
}

// The handler decides recovery strategy
const handler = Handler(Throw, ?i32){
    .handle_fn = &struct {
        fn handle(err: anyerror, ctx: *RC) ?i32 {
            log.err("caught: {}", .{err});
            return null;  // short-circuit with null
        }
    }.handle,
};
```

## Cross-Thread Communication

Only two cross-thread channels exist:

1. **Acceptor → Worker inbox**: SPSC queue (one producer, one consumer). Lock-free. Worker drains on each loop iteration.
2. **Offload pool → Worker completions**: The offload thread writes a result and wakes the originating worker via `EVFILT_USER` (kqueue) or `eventfd` (Linux).

No other cross-thread communication on the I/O hot path.

### WakeupFd

Each worker has a wakeup mechanism registered with its kqueue:

- **macOS**: `EVFILT_USER` — a kqueue filter that fires when you trigger it from another thread via `kevent()`. No file descriptor needed.
- **Linux**: `eventfd` — a file descriptor that becomes readable when written to. Register with epoll/io_uring.

## What Changes, What Stays

### Stays Exactly The Same

| Component | Why |
|-----------|-----|
| `arch/*` | Context switch is per-fiber, fiber stays on one thread |
| `core/fiber.zig` | Fiber lifecycle unchanged |
| `core/fiber_pool.zig` | Already thread-local |
| `core/prompt.zig` | Delimited continuations are fiber-local |
| `core/stack_signal.zig` | Signal handler is process-wide |
| `effects/effect.zig` | `perform()` unchanged — thread-local channel |
| `effects/handler.zig` | Handler dispatch is fiber-local |
| `effects/io.zig` | Effect type definitions unchanged |
| `runtime/blocking.zig` | Still useful for scripts/testing |
| `runtime/testing.zig` | Deterministic mock stays |
| `platform/*` | VM operations are stateless |

### Needs Modification

| Component | Change |
|-----------|--------|
| `runtime/kqueue.zig` | Extract reusable EventLoop from monolithic `runServer`. Accept logic moves to Acceptor. |

### New Code (~1,000 lines total)

| File | Lines | Description |
|------|-------|-------------|
| `runtime/runtime.zig` | ~250 | Runtime struct, init, spawn workers, shutdown |
| `runtime/worker.zig` | ~200 | Worker thread: event loop + fiber scheduler |
| `runtime/acceptor.zig` | ~80 | Accept thread + connection distribution |
| `runtime/offload.zig` | ~120 | Bounded thread pool for CPU work |
| `runtime/sync.zig` | ~150 | SpscQueue, WakeupFd, MpmcQueue |
| `effects/result.zig` | ~100 | Result(T, E) with map/andThen/mapErr |
| `effects/pipeline.zig` | ~80 | Comptime pipeline composition |

### Implementation Order

```
Phase 1: Result + Pipeline (no threading, pure library code)
Phase 2: Refactor kqueue.zig → extract reusable EventLoop
Phase 3: Runtime struct with threads=1 (single-threaded through new API)
Phase 4: Multi-threaded: acceptor, SPSC inbox, wakeup fds
Phase 5: Offload pool + Offload effect
```

## Comparison to Other Runtimes

| | Reshift | Tokio | libuv | Go |
|---|---|---|---|---|
| **Execution unit** | Fiber (8MB virtual stack) | Future (stackless state machine) | Callback | Goroutine (growable stack) |
| **Scheduling** | Per-thread run queue | Work-stealing deque | Single-threaded | Work-stealing per-P |
| **Fiber migration** | No (pinned to thread) | Yes (futures are Send) | N/A | Yes |
| **Function coloring** | **None** | Yes (async/sync divide) | Yes (callbacks) | **None** |
| **Testability** | Swap handler for mock | cfg(test) / trait objects | Manual mocking | Manual mocking |
| **I/O mechanism** | kqueue/io_uring | mio (epoll/kqueue) | epoll/kqueue/IOCP | netpoller |
| **CPU offload** | Offload effect | spawn_blocking | uv_queue_work | LockOSThread |
| **Memory per task** | 64KB committed | ~hundreds of bytes | ~closure size | 8KB initial |
| **Max concurrent** | ~10K-100K | ~1M+ | ~100K | ~100K-1M |

### Where Reshift Wins

1. **No function coloring.** `io.Read.perform()` is a normal call. Same code works blocking, async, or mocked.
2. **Effect handler testability.** Install `testing.MockHandler` and your code runs deterministically with canned I/O. No other runtime does this.
3. **Simpler mental model.** Sequential code on real stacks. No `Pin<Box<dyn Future>>`, no lifetime bounds, no `Send` requirements.

### Where Reshift Loses (Acceptable)

1. **No work stealing for I/O tasks.** For network servers with uniform connections this barely matters. For compute-heavy work, use the Offload effect.
2. **Higher per-fiber memory.** 64KB vs Tokio's hundreds of bytes per future. At 10K connections that's 640MB vs ~10MB. Mitigated by signal handler path (16KB initial) → 160MB for 10K fibers.
3. **Smaller scale ceiling.** Won't hit 1M concurrent fibers like Tokio can. 10K-100K is the practical range, which covers most server workloads.
