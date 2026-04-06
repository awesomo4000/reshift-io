#!/usr/bin/env python3
"""Benchmark the reshift echo server.

Starts the server, runs latency + throughput + memory tests, then cleans up.
Build first: zig build -Doptimize=ReleaseFast
"""

import socket
import subprocess
import time
import os
import signal
import sys

PORT = 8080
SERVER_BIN = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "echo_server")


def wait_for_port(port, timeout=5):
    start = time.time()
    while time.time() - start < timeout:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect(("127.0.0.1", port))
            s.close()
            return True
        except ConnectionRefusedError:
            time.sleep(0.05)
    return False


def get_memory_kb(pid):
    """Get RSS in KB."""
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)])
        return int(out.strip())
    except Exception:
        return 0


def get_vsz_kb(pid):
    """Get virtual size in KB."""
    try:
        out = subprocess.check_output(["ps", "-o", "vsz=", "-p", str(pid)])
        return int(out.strip())
    except Exception:
        return 0


def recv_exact(s, n):
    """Receive exactly n bytes."""
    data = b""
    while len(data) < n:
        chunk = s.recv(min(65536, n - len(data)))
        if not chunk:
            break
        data += chunk
    return data


def main():
    if not os.path.exists(SERVER_BIN):
        print(f"Server binary not found: {SERVER_BIN}")
        print("Build first: zig build -Doptimize=ReleaseFast")
        sys.exit(1)

    # Kill any existing server
    subprocess.run(["pkill", "-f", "echo_server"], capture_output=True)
    time.sleep(0.5)

    # Start server
    server = subprocess.Popen(
        [SERVER_BIN],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    if not wait_for_port(PORT):
        print("Server failed to start")
        server.kill()
        sys.exit(1)

    pid = server.pid
    print(f"reshift echo server benchmark (pid={pid})")
    print("=" * 50)

    # ── Memory: idle ──────────────────────────────────
    rss_idle = get_memory_kb(pid)
    vsz_idle = get_vsz_kb(pid)
    print(f"\nMemory (idle):")
    print(f"  RSS:     {rss_idle:,} KB ({rss_idle/1024:.1f} MB)")
    print(f"  Virtual: {vsz_idle:,} KB ({vsz_idle/1024:.0f} MB)")

    # ── Latency: persistent connection ────────────────
    print(f"\nLatency (10K round trips, persistent connection):")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(("127.0.0.1", PORT))
    msg = b"hello world!\n"
    msglen = len(msg)

    # Warmup
    for _ in range(200):
        s.sendall(msg)
        recv_exact(s, msglen)

    rounds = 10000
    start = time.perf_counter()
    for _ in range(rounds):
        s.sendall(msg)
        recv_exact(s, msglen)
    elapsed = time.perf_counter() - start
    s.close()
    time.sleep(0.1)  # let server cycle back to accept

    rss_lat = get_memory_kb(pid)
    print(f"  {rounds:,} round trips in {elapsed:.3f}s")
    print(f"  {rounds/elapsed:,.0f} req/s")
    print(f"  {elapsed/rounds*1e6:.1f} us/req")
    print(f"  RSS: {rss_lat:,} KB")

    # ── Throughput: bulk echo ─────────────────────────
    print(f"\nThroughput (10 MB bulk echo):")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(("127.0.0.1", PORT))
    size = 10 * 1024 * 1024
    data = b"x" * size

    start = time.perf_counter()
    s.sendall(data)
    s.shutdown(socket.SHUT_WR)  # signal EOF so server finishes
    received = recv_exact(s, size)
    elapsed = time.perf_counter() - start
    s.close()
    time.sleep(0.1)

    rss_bulk = get_memory_kb(pid)
    print(f"  {len(received)/1024/1024:.0f} MB in {elapsed:.3f}s")
    print(f"  {len(received)/1024/1024/elapsed:,.0f} MB/s")
    print(f"  RSS: {rss_bulk:,} KB")

    # ── Connection churn ──────────────────────────────
    print(f"\nConnection churn (200 connect/echo/close cycles):")
    start = time.perf_counter()
    for _ in range(200):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(("127.0.0.1", PORT))
        s.sendall(b"ping\n")
        recv_exact(s, 5)
        s.close()
    elapsed = time.perf_counter() - start

    rss_churn = get_memory_kb(pid)
    print(f"  200 cycles in {elapsed:.3f}s")
    print(f"  {200/elapsed:,.0f} conn/s")
    print(f"  RSS: {rss_churn:,} KB")

    # ── Summary ───────────────────────────────────────
    vsz_final = get_vsz_kb(pid)
    print(f"\n{'='*50}")
    print(f"Memory summary:")
    print(f"  Idle:          {rss_idle:>8,} KB")
    print(f"  After latency: {rss_lat:>8,} KB")
    print(f"  After bulk:    {rss_bulk:>8,} KB")
    print(f"  After churn:   {rss_churn:>8,} KB")
    print(f"  Virtual:       {vsz_final:>8,} KB ({vsz_final/1024:.0f} MB)")

    server.send_signal(signal.SIGTERM)
    server.wait(timeout=3)
    print(f"\nDone.")


if __name__ == "__main__":
    main()
