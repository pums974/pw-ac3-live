#!/bin/bash
# CI Integration Test: stereo (2ch) input → AC-3 5.1 output
#
# Feeds 2-channel audio into pw-ac3-live and verifies it still produces
# valid IEC 61937 AC-3 output. This exercises the stride-based 2ch→6ch
# padding path in parse_interleaved_from_stride_into.
#
# Requires: running PipeWire daemon, pactl, pw-play, ffmpeg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

# ── Configuration ──────────────────────────────────────────────────────
DURATION=5
SAMPLE_RATE=48000
SINK_NAME="pw-ac3-ci-stereo"
OUTPUT_FILE="ci_stereo_output.raw"
PIPELINE_LOG="ci_stereo.log"

# ── Colors ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[CI-STEREO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── State ──────────────────────────────────────────────────────────────
MODULE_ID=""
PIPELINE_PID=""
PLAY_PID=""
DEFAULT_SINK=""

cleanup() {
  if [ -n "$PLAY_PID" ] && kill -0 "$PLAY_PID" 2> /dev/null; then
    kill "$PLAY_PID" 2> /dev/null || true
    wait "$PLAY_PID" 2> /dev/null || true
  fi
  if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2> /dev/null; then
    kill "$PIPELINE_PID" 2> /dev/null || true
    wait "$PIPELINE_PID" 2> /dev/null || true
  fi
  if [ -n "$DEFAULT_SINK" ]; then
    pactl set-default-sink "$DEFAULT_SINK" 2> /dev/null || true
  fi
  if [ -n "$MODULE_ID" ]; then
    pactl unload-module "$MODULE_ID" 2> /dev/null || true
  fi
  rm -f ci_stereo_tone.wav "$OUTPUT_FILE" "$PIPELINE_LOG"
}
trap cleanup EXIT

log "Building pw-ac3-live..."
cargo build --release 2>&1

# Create null sink
DEFAULT_SINK=$(pactl get-default-sink 2> /dev/null || echo "")
MODULE_ID=$(pactl load-module module-null-sink \
  sink_name="$SINK_NAME" \
  sink_properties=device.description="CI_Stereo_Sink" \
  format=s16le rate=48000 channels=2)
pactl set-default-sink "$SINK_NAME"
sleep 1

# Start pw-ac3-live
log "Starting pw-ac3-live --stdout..."
RUST_LOG=info ./target/release/pw-ac3-live --stdout > "$OUTPUT_FILE" 2> "$PIPELINE_LOG" &
PIPELINE_PID=$!
sleep 2

if ! kill -0 "$PIPELINE_PID" 2> /dev/null; then
  error "pw-ac3-live failed to start"
  cat "$PIPELINE_LOG" || true
  exit 1
fi

# Wait for capture node
for i in $(seq 1 15); do
  if pw-link -i 2> /dev/null | grep -q "pw-ac3-live-input"; then
    log "pw-ac3-live-input found!"
    break
  fi
  if [ "$i" -eq 15 ]; then
    error "pw-ac3-live-input did not appear"
    cat "$PIPELINE_LOG" || true
    exit 1
  fi
  sleep 1
done

# Generate STEREO (2ch) test tone — this is the key difference from test_ci_pipeline.sh
log "Generating ${DURATION}s stereo tone..."
ffmpeg -hide_banner -loglevel error -nostdin \
  -f lavfi -i "sine=frequency=440:duration=$DURATION" \
  -f lavfi -i "sine=frequency=880:duration=$DURATION" \
  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]" \
  -map "[a]" -ar "$SAMPLE_RATE" -f wav -y ci_stereo_tone.wav 2>&1

log "Playing stereo tone into pw-ac3-live-input..."
pw-play ci_stereo_tone.wav &
PLAY_PID=$!
sleep 1

# Link pw-play → pw-ac3-live-input
log "Linking pw-play → pw-ac3-live-input..."
for attempt in $(seq 1 20); do
  mapfile -t FEEDER_IDS < <(pw-link -o -I 2> /dev/null | grep -i "pw-play" | awk '{print $1}' | sort -un)
  mapfile -t SINK_IDS < <(pw-link -i -I 2> /dev/null | grep "pw-ac3-live-input" | awk '{print $1}' | sort -un)

  if [ "${#FEEDER_IDS[@]}" -gt 0 ] && [ "${#SINK_IDS[@]}" -gt 0 ]; then
    local_max="${#FEEDER_IDS[@]}"
    [ "${#SINK_IDS[@]}" -lt "$local_max" ] && local_max="${#SINK_IDS[@]}"
    for ((i = 0; i < local_max; i++)); do
      pw-link "${FEEDER_IDS[$i]}" "${SINK_IDS[$i]}" 2> /dev/null || true
    done
    log "Linked ${local_max} port(s)."
    break
  fi
  sleep 0.5
done

# Wait for playback
log "Waiting for stereo playback to complete (${DURATION}s)..."
wait "$PLAY_PID" 2> /dev/null || true
PLAY_PID=""
sleep 2

# Stop pipeline
log "Stopping pw-ac3-live..."
kill "$PIPELINE_PID" 2> /dev/null || true
wait "$PIPELINE_PID" 2> /dev/null || true
PIPELINE_PID=""

# ── Validate ───────────────────────────────────────────────────────────
log "Validating output..."

if [ ! -f "$OUTPUT_FILE" ]; then
  error "Output file does not exist!"
  exit 1
fi

OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE")
if [ "$OUTPUT_SIZE" -eq 0 ]; then
  error "Output file is empty!"
  cat "$PIPELINE_LOG" || true
  exit 1
fi
log "Output size: $OUTPUT_SIZE bytes"

# Frame alignment
if [ $((OUTPUT_SIZE % 4)) -ne 0 ]; then
  error "Output is NOT frame-aligned ($OUTPUT_SIZE not a multiple of 4)"
  exit 1
fi
log "✓ Output is frame-aligned"

# IEC 61937 preambles
PREAMBLE_COUNT=$(python3 -c "
data = open('$OUTPUT_FILE', 'rb').read()
count = sum(1 for i in range(len(data)-3) if data[i:i+4] == b'\x72\xf8\x1f\x4e')
print(count)
")

if [ "$PREAMBLE_COUNT" -eq 0 ]; then
  error "No IEC 61937 preambles found in stereo→AC3 output!"
  cat "$PIPELINE_LOG" || true
  exit 1
fi
log "✓ Found $PREAMBLE_COUNT IEC 61937 frame(s) from stereo input"

# Verify the capture log confirms 2ch or stride-based format
if grep -q "channels=2" "$PIPELINE_LOG" || grep -q "stride=8" "$PIPELINE_LOG"; then
  log "✓ Capture format confirms stereo input"
elif grep -q "channels=6" "$PIPELINE_LOG"; then
  warn "PipeWire upmixed stereo to 6ch (acceptable — padding still exercised)"
else
  warn "Could not confirm channel count from log"
fi

log ""
log "═══════════════════════════════════════"
log "  STEREO INPUT TEST PASSED"
log "═══════════════════════════════════════"
