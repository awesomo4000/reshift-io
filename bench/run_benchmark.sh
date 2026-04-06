#!/bin/bash
# run_benchmark.sh — Head-to-head: reshift vs raw C kqueue echo server
#
# Usage: ./bench/run_benchmark.sh
# (run from the reshift-io root directory)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
C_PORT=9990
RESHIFT_PORT=9991
BUILD_DIR="/tmp/reshift-bench"

mkdir -p "$BUILD_DIR"

echo "═══════════════════════════════════════════════════════"
echo "  reshift-io vs raw C kqueue echo — head-to-head"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Compile ──────────────────────────────────────────────
echo "Building..."

# C baseline
cc -O2 -o "$BUILD_DIR/raw_echo" "$SCRIPT_DIR/c_baseline/raw_echo.c"
cc -O2 -pthread -o "$BUILD_DIR/bench_client" "$SCRIPT_DIR/c_baseline/bench_client.c"
echo "  [ok] C baseline compiled"

# reshift echo server
(cd "$ROOT_DIR" && zig build -Doptimize=ReleaseFast 2>&1) || {
    echo "  [FAIL] zig build failed"
    exit 1
}
echo "  [ok] reshift echo server built"
echo ""

# ── Cleanup function ─────────────────────────────────────
cleanup() {
    kill $C_PID 2>/dev/null || true
    kill $R_PID 2>/dev/null || true
    wait $C_PID 2>/dev/null || true
    wait $R_PID 2>/dev/null || true
}
trap cleanup EXIT

# ── Run C baseline ───────────────────────────────────────
echo "━━━ Raw C kqueue echo server ━━━"
"$BUILD_DIR/raw_echo" $C_PORT &
C_PID=$!
sleep 0.3

"$BUILD_DIR/bench_client" $C_PORT
C_RESULT=$("$BUILD_DIR/bench_client" $C_PORT)

# Get C server RSS
C_RSS=$(ps -o rss= -p $C_PID 2>/dev/null || echo "0")
C_RSS_MB=$(echo "scale=1; $C_RSS / 1024" | bc 2>/dev/null || echo "?")

kill $C_PID 2>/dev/null || true
wait $C_PID 2>/dev/null || true
sleep 0.3
echo ""

# ── Run reshift ──────────────────────────────────────────
echo "━━━ reshift kqueue echo server ━━━"
"$ROOT_DIR/zig-out/bin/echo_server" async &
R_PID=$!
sleep 0.5

"$BUILD_DIR/bench_client" 8080
R_RESULT=$("$BUILD_DIR/bench_client" 8080)

# Get reshift server RSS
R_RSS=$(ps -o rss= -p $R_PID 2>/dev/null || echo "0")
R_RSS_MB=$(echo "scale=1; $R_RSS / 1024" | bc 2>/dev/null || echo "?")

kill $R_PID 2>/dev/null || true
wait $R_PID 2>/dev/null || true
echo ""

# ── Extract throughput numbers ───────────────────────────
C_THROUGHPUT=$(echo "$C_RESULT" | grep "Throughput:" | awk '{print $2}')
C_LATENCY=$(echo "$C_RESULT" | grep "round-trip:" | awk '{print $3}')
R_THROUGHPUT=$(echo "$R_RESULT" | grep "Throughput:" | awk '{print $2}')
R_LATENCY=$(echo "$R_RESULT" | grep "round-trip:" | awk '{print $3}')

# ── Summary ──────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  RESULTS (50 clients x 10K messages = 500K total)"
echo "═══════════════════════════════════════════════════════"
echo ""
printf "  %-20s %15s %15s %10s\n" "" "Throughput" "Avg Latency" "RSS"
printf "  %-20s %15s %15s %10s\n" "────────────────────" "───────────────" "───────────────" "──────────"
printf "  %-20s %12s msg/s %12s us %7s MB\n" "Raw C kqueue" "$C_THROUGHPUT" "$C_LATENCY" "$C_RSS_MB"
printf "  %-20s %12s msg/s %12s us %7s MB\n" "reshift (effects)" "$R_THROUGHPUT" "$R_LATENCY" "$R_RSS_MB"
echo ""
echo "═══════════════════════════════════════════════════════"
echo ""

if [ -n "$C_THROUGHPUT" ] && [ -n "$R_THROUGHPUT" ]; then
    RATIO=$(echo "scale=1; $R_THROUGHPUT * 100 / $C_THROUGHPUT" | bc 2>/dev/null || echo "?")
    echo "  reshift is ${RATIO}% of raw C throughput"
    echo "  (100% = identical, >95% = within noise)"
fi
echo ""
