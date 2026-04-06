# reshift-io

I/O runtime for [reshift](https://github.com/awesomo4000/reshift) algebraic effects.

reshift is the core library: delimited continuations, Effect, Handler, fibers, virtual memory tricks. **reshift-io** provides the I/O effects and event loops that make it useful for real network servers.

## The pitch

Write server code in direct style. No async/await, no callbacks, no function coloring. The **same code** runs blocking, async, or under a deterministic test harness — just swap the handler.

```zig
fn handleConnection(fd: posix.fd_t) void {
    defer io.Close.perform(fd);
    var buf: [4096]u8 = undefined;

    while (true) {
        const read_result = io.Read.perform(.{ .fd = fd, .buffer = &buf });
        switch (read_result) {
            .ok => |n| {
                var written: usize = 0;
                while (written < n) {
                    switch (io.Write.perform(.{ .fd = fd, .data = buf[written..n] })) {
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
```

This function has no idea if it's running on a blocking thread, a kqueue event loop, or a mock test runtime. `io.Read.perform()` and `io.Write.perform()` are normal function calls — the handler installed higher up the stack decides how they execute.

## Performance

Head-to-head against a raw C kqueue echo server (single-threaded, no framework, just `kevent` + `read` + `write`):

```
═══════════════════════════════════════════════════════
  RESULTS (50 clients x 10K messages = 500K total)
═══════════════════════════════════════════════════════

                            Throughput     Avg Latency        RSS
  Raw C kqueue                76732 msg/s        651.6 us     1.2 MB
  reshift (effects)           77005 msg/s        649.3 us     1.6 MB

  reshift is 100.3% of raw C throughput
```

The algebraic effects overhead is invisible at the network I/O scale.

## Quick start

Requires **Zig 0.15+** and [reshift](https://github.com/awesomo4000/reshift) as a sibling directory (or update the path in `build.zig.zon`).

```bash
# Build
zig build
zig build -Doptimize=ReleaseFast   # for benchmarks

# Run the echo server
zig build run-echo_server           # blocking mode
zig build run-echo_server -- async  # kqueue async mode

# Test with: echo "hello" | nc localhost 8080

# Run tests
zig build test

# Run benchmarks
bash bench/run_benchmark.sh         # head-to-head vs C
python3 bench/echo_bench.py         # latency/throughput/memory profiler
zig build run-kqueue_bench -Doptimize=ReleaseFast  # Zig-native bench
```

## What's in the box

### Effects (`src/effects/`)
- **`io.zig`** — `Read`, `Write`, `Accept`, `Close`
- **`builtins.zig`** — `Sleep`, `Spawn`, `Join`, `Log`

### Runtimes (`src/runtime/`)
- **`blocking.zig`** — Synchronous POSIX handlers. One connection at a time. Good for scripts and debugging.
- **`kqueue.zig`** — Async event loop for macOS/BSD. Multiplexes thousands of fibers on one thread.
- **`testing.zig`** — Deterministic mock. Queue fake reads, inspect recorded writes. No real I/O.
- **`epoll.zig`** / **`iouring.zig`** — Linux stubs (not yet implemented).

### Examples
- **`echo_server.zig`** — TCP echo server demonstrating both blocking and async modes with identical `handleConnection()` code.

### Benchmarks
- **`bench/run_benchmark.sh`** — Head-to-head: reshift vs raw C kqueue echo server.
- **`bench/echo_bench.py`** — Latency, throughput, memory, and connection churn profiler.
- **`bench/kqueue_bench.zig`** — Zig-native throughput benchmark (50 client threads).
- **`bench/c_baseline/`** — The raw C echo server and benchmark client used for comparison.

## Architecture

See [DESIGN.md](DESIGN.md) for the multi-threaded runtime architecture plan (thread-per-loop, acceptor, CPU offload pool, SPSC queues).

## License

Same as [reshift](https://github.com/awesomo4000/reshift).
