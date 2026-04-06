# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**reshift-io** is the I/O runtime package for [reshift](https://github.com/awesomo4000/reshift). It provides I/O effect definitions and runtime implementations built on reshift's algebraic effect primitives.

reshift is the core library (delimited continuations, Effect, Handler, fibers, virtual memory). reshift-io provides the concrete I/O effects and event loops that make reshift useful for network servers and real I/O workloads.

Requires **Zig 0.15+** and depends on reshift via path dependency (`../reshift`).

## Build & Test Commands

```bash
zig build                          # build library + examples + benches
zig build test                     # run all tests
zig build test -- --filter "name"  # run a single test by name
zig build -Doptimize=ReleaseFast   # optimized build (for benchmarks)
zig build run-echo_server          # run the echo server (blocking mode)
zig build run-echo_server -- async # run the echo server (kqueue async mode)
zig build run-kqueue_bench         # run the kqueue benchmark
```

## Architecture

### Effect Definitions (`src/effects/`)
- **`io.zig`** — Read, Write, Accept, Close effects for network I/O. Each is an `Effect("Name", Request, Response)` using reshift's comptime factory.
- **`builtins.zig`** — Sleep, Spawn, Join, Log utility effects.

### Runtime Implementations (`src/runtime/`)
- **`blocking.zig`** — Tail-resumptive handlers doing real POSIX syscalls. Sequential, one connection at a time. `runWithIO(Result, body)` installs all IO handlers.
- **`kqueue.zig`** — Async event loop for macOS/BSD. Multiplexes fibers on a single thread via kqueue. Per-task `EffectChannel` save/restore for concurrent fiber multiplexing. `runServer(allocator, listen_fd, handler)` is the public API.
- **`testing.zig`** — Deterministic mock runtime (canned reads, recorded writes, no real I/O). Use `TestRuntime.init()`, `expectRead()`, `handleRead()`, `handleWrite()`, `getWrites()`.
- **`epoll.zig`** — Stub (Linux, not yet implemented).
- **`iouring.zig`** — Stub (Linux, not yet implemented).

### Public API (`src/root.zig`)
Re-exports: `io`, `builtins`, `blocking_runtime`, `kqueue_runtime`, `testing_runtime`, `epoll_runtime`, `iouring_runtime`.

### Tests (`tests/`)
- **`integration_test.zig`** — Tests the mock testing runtime (read/write/eof).
- **`kqueue_test.zig`** — Tests the kqueue event loop with real sockets.

### Examples (`examples/`)
- **`echo_server.zig`** — TCP echo server demonstrating both blocking and async kqueue modes with the same `handleConnection()` code.

### Benchmarks (`bench/`)
- **`kqueue_bench.zig`** — Performance benchmark for the kqueue runtime.

## Key Import Pattern

Files in this package import from two sources:
- `@import("reshift")` — core primitives (Effect, Handler, arch, fiber, prompt, EffectChannel)
- Local relative imports — `@import("../effects/io.zig")` for I/O effect types within this package

User code imports:
- `@import("reshift-io")` — for io effects and runtimes

## Design Document

See `DESIGN.md` for the multi-threaded runtime architecture plan, including threading model, worker/acceptor design, CPU offload pool, and comparison to Tokio/libuv/Go.
