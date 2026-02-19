#!/bin/bash
# CI Integration Test: graceful SIGINT shutdown
#
# Starts pw-ac3-live --stdout, feeds audio briefly, sends SIGINT,
# and verifies a clean exit (code 0, no panics in log).
#
# Requires: running PipeWire daemon, pactl, pw-play, ffmpeg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[CI-SIGINT]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SINK_NAME="pw-ac3-ci-sigint"
PIPELINE_LOG="ci_sigint.log"
OUTPUT_FILE="ci_sigint_output.raw"
MODULE_ID=""
PIPELINE_PID=""
PLAY_PID=""
DEFAULT_SINK=""

cleanup() {
    if [ -n "$PLAY_PID" ] && kill -0 "$PLAY_PID" 2>/dev/null; then
        kill "$PLAY_PID" 2>/dev/null || true
        wait "$PLAY_PID" 2>/dev/null || true
    fi
    if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2>/dev/null; then
        kill "$PIPELINE_PID" 2>/dev/null || true
        wait "$PIPELINE_PID" 2>/dev/null || true
    fi
    if [ -n "$DEFAULT_SINK" ]; then
        pactl set-default-sink "$DEFAULT_SINK" 2>/dev/null || true
    fi
    if [ -n "$MODULE_ID" ]; then
        pactl unload-module "$MODULE_ID" 2>/dev/null || true
    fi
    rm -f ci_sigint_tone.wav "$OUTPUT_FILE" "$PIPELINE_LOG"
}
trap cleanup EXIT

log "Building pw-ac3-live..."
cargo build --release 2>&1

# Create null sink
DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null || echo "")
MODULE_ID=$(pactl load-module module-null-sink \
    sink_name="$SINK_NAME" \
    sink_properties=device.description="CI_SIGINT_Sink" \
    format=s16le rate=48000 channels=2)
pactl set-default-sink "$SINK_NAME"
sleep 1

# Start pw-ac3-live
RUST_LOG=info ./target/release/pw-ac3-live --stdout >"$OUTPUT_FILE" 2>"$PIPELINE_LOG" &
PIPELINE_PID=$!
sleep 2

if ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
    error "pw-ac3-live failed to start"
    cat "$PIPELINE_LOG" || true
    exit 1
fi

# Wait for capture node
for i in $(seq 1 10); do
    if pw-link -i 2>/dev/null | grep -q "pw-ac3-live-input"; then
        break
    fi
    sleep 1
done

# Feed a short tone (2s) to get it streaming
ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=880:duration=2" \
    -f lavfi -i "sine=frequency=1320:duration=2" \
    -f lavfi -i "sine=frequency=100:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -f lavfi -i "sine=frequency=1100:duration=2" \
    -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
    -map "[a]" -ar 48000 -f wav -y ci_sigint_tone.wav 2>&1

pw-play ci_sigint_tone.wav &
PLAY_PID=$!
sleep 1

# Link
mapfile -t FEEDER_IDS < <(pw-link -o -I 2>/dev/null | grep -i "pw-play" | awk '{print $1}' | sort -un)
mapfile -t SINK_IDS   < <(pw-link -i -I 2>/dev/null | grep "pw-ac3-live-input" | awk '{print $1}' | sort -un)
if [ "${#FEEDER_IDS[@]}" -gt 0 ] && [ "${#SINK_IDS[@]}" -gt 0 ]; then
    local_max="${#FEEDER_IDS[@]}"
    [ "${#SINK_IDS[@]}" -lt "$local_max" ] && local_max="${#SINK_IDS[@]}"
    for ((i = 0; i < local_max; i++)); do
        pw-link "${FEEDER_IDS[$i]}" "${SINK_IDS[$i]}" 2>/dev/null || true
    done
fi

# Let it stream briefly
sleep 1

# Send SIGINT (like Ctrl+C)
log "Sending SIGINT to pw-ac3-live (PID $PIPELINE_PID)..."
kill -INT "$PIPELINE_PID"

# Wait for clean exit
EXIT_CODE=0
wait "$PIPELINE_PID" 2>/dev/null || EXIT_CODE=$?
PIPELINE_PID=""

# Also stop pw-play
if [ -n "$PLAY_PID" ] && kill -0 "$PLAY_PID" 2>/dev/null; then
    kill "$PLAY_PID" 2>/dev/null || true
    wait "$PLAY_PID" 2>/dev/null || true
fi
PLAY_PID=""

# Validate
if [ "$EXIT_CODE" -ne 0 ]; then
    error "pw-ac3-live exited with code $EXIT_CODE after SIGINT (expected 0)"
    cat "$PIPELINE_LOG" || true
    exit 1
fi
log "✓ Exit code 0 after SIGINT"

# Check for panics in log
if grep -qi "panic" "$PIPELINE_LOG"; then
    error "Found 'panic' in log after SIGINT!"
    cat "$PIPELINE_LOG"
    exit 1
fi
log "✓ No panics in log"

# Verify some output was produced before shutdown
OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0)
if [ "$OUTPUT_SIZE" -gt 0 ]; then
    log "✓ Produced $OUTPUT_SIZE bytes of output before shutdown"
else
    log "  (No output produced — acceptable if audio hadn't started flowing yet)"
fi

log "✓ Graceful SIGINT shutdown test passed"
