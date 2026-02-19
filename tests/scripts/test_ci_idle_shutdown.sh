#!/bin/bash
# CI Integration Test: idle shutdown without any audio input
#
# Starts pw-ac3-live --stdout, waits without feeding any audio,
# sends SIGINT, and verifies a clean exit (no hang, no panic).
#
# Requires: running PipeWire daemon, pactl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[CI-IDLE]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SINK_NAME="pw-ac3-ci-idle"
PIPELINE_LOG="ci_idle.log"
OUTPUT_FILE="ci_idle_output.raw"
MODULE_ID=""
PIPELINE_PID=""
DEFAULT_SINK=""

cleanup() {
    if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2>/dev/null; then
        kill -9 "$PIPELINE_PID" 2>/dev/null || true
        wait "$PIPELINE_PID" 2>/dev/null || true
    fi
    if [ -n "$DEFAULT_SINK" ]; then
        pactl set-default-sink "$DEFAULT_SINK" 2>/dev/null || true
    fi
    if [ -n "$MODULE_ID" ]; then
        pactl unload-module "$MODULE_ID" 2>/dev/null || true
    fi
    rm -f "$OUTPUT_FILE" "$PIPELINE_LOG"
}
trap cleanup EXIT

log "Building pw-ac3-live..."
cargo build --release 2>&1

# Create null sink
DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null || echo "")
MODULE_ID=$(pactl load-module module-null-sink \
    sink_name="$SINK_NAME" \
    sink_properties=device.description="CI_Idle_Sink" \
    format=s16le rate=48000 channels=2)
pactl set-default-sink "$SINK_NAME"
sleep 1

# Start pw-ac3-live (no audio will be fed)
log "Starting pw-ac3-live --stdout (no audio will be fed)..."
RUST_LOG=info ./target/release/pw-ac3-live --stdout >"$OUTPUT_FILE" 2>"$PIPELINE_LOG" &
PIPELINE_PID=$!

# Wait for it to start and idle for a few seconds
sleep 3

if ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
    error "pw-ac3-live exited prematurely without any input!"
    cat "$PIPELINE_LOG" || true
    exit 1
fi
log "✓ pw-ac3-live is still running after 3s of idle"

# Send SIGINT
log "Sending SIGINT..."
kill -INT "$PIPELINE_PID"

# Wait with a timeout (should exit within 5s)
TIMEOUT=5
EXIT_CODE=0
for i in $(seq 1 $((TIMEOUT * 10))); do
    if ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if kill -0 "$PIPELINE_PID" 2>/dev/null; then
    error "pw-ac3-live did NOT exit within ${TIMEOUT}s after SIGINT — HUNG!"
    kill -9 "$PIPELINE_PID" 2>/dev/null || true
    wait "$PIPELINE_PID" 2>/dev/null || true
    PIPELINE_PID=""
    cat "$PIPELINE_LOG" || true
    exit 1
fi

wait "$PIPELINE_PID" 2>/dev/null || EXIT_CODE=$?
PIPELINE_PID=""

if [ "$EXIT_CODE" -ne 0 ]; then
    error "pw-ac3-live exited with code $EXIT_CODE (expected 0)"
    cat "$PIPELINE_LOG" || true
    exit 1
fi
log "✓ Exit code 0"

# Check for panics
if grep -qi "panic" "$PIPELINE_LOG"; then
    error "Found 'panic' in log!"
    cat "$PIPELINE_LOG"
    exit 1
fi
log "✓ No panics in log"

# Output should be empty or near-empty (no audio was fed)
OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0)
log "  Output size: $OUTPUT_SIZE bytes (expected 0 or near-zero)"

log "✓ Idle shutdown test passed"
