#!/bin/bash
# CI Integration Test: headless PipeWire end-to-end pipeline
#
# Starts pw-ac3-live in --stdout mode, feeds 6ch silence into its capture
# node via the default sink, and validates that the output contains
# IEC 61937 AC-3 frames.
#
# Requirements: pipewire, wireplumber, pipewire-pulse (pactl), pw-play, ffmpeg
# This script is designed to run inside a dbus-run-session with PipeWire active.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

# ── Configuration ──────────────────────────────────────────────────────
DURATION=5
SAMPLE_RATE=48000
CHANNELS=6
SINK_NAME="pw-ac3-ci-sink"
OUTPUT_FILE="ci_output.raw"
PIPELINE_LOG="ci_pipeline.log"

# ── Colors ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[CI-TEST]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── State ──────────────────────────────────────────────────────────────
MODULE_ID=""
PIPELINE_PID=""
PLAY_PID=""
DEFAULT_SINK=""

cleanup() {
  log "Cleaning up..."

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
}
trap cleanup EXIT

# ── 1. Check dependencies ─────────────────────────────────────────────
log "Checking dependencies..."
for cmd in cargo ffmpeg pw-play pactl pw-link; do
  command -v "$cmd" > /dev/null 2>&1 || {
    error "$cmd not found"
    exit 1
  }
done

# Verify PipeWire is actually running
if ! pw-cli info 0 > /dev/null 2>&1; then
  error "PipeWire daemon is not running"
  exit 1
fi
log "PipeWire daemon is alive."

rm -f "$OUTPUT_FILE" "$PIPELINE_LOG"

# ── 2. Build ───────────────────────────────────────────────────────────
log "Building pw-ac3-live..."
cargo build --release 2>&1

# ── 3. Create null sink and set as default ─────────────────────────────
log "Loading null sink '$SINK_NAME'..."
DEFAULT_SINK=$(pactl get-default-sink 2> /dev/null || echo "")
MODULE_ID=$(pactl load-module module-null-sink \
  sink_name="$SINK_NAME" \
  sink_properties=device.description="CI_Test_Sink" \
  format=s16le rate=48000 channels=2)
if [ -z "$MODULE_ID" ]; then
  error "Failed to load module-null-sink"
  exit 1
fi
log "Loaded module $MODULE_ID"

# Make it the default so pw-play autoconnects to it (driving the graph)
pactl set-default-sink "$SINK_NAME"
sleep 1

# ── 4. Start pw-ac3-live in stdout mode ────────────────────────────────
log "Starting pw-ac3-live --stdout..."
RUST_LOG=info ./target/release/pw-ac3-live --stdout > "$OUTPUT_FILE" 2> "$PIPELINE_LOG" &
PIPELINE_PID=$!
sleep 2

if ! kill -0 "$PIPELINE_PID" 2> /dev/null; then
  error "pw-ac3-live failed to start. Log:"
  cat "$PIPELINE_LOG" || true
  exit 1
fi
log "pw-ac3-live running (PID $PIPELINE_PID)."

# Wait for the capture node to appear
log "Waiting for pw-ac3-live-input node..."
for i in $(seq 1 15); do
  if pw-link -i 2> /dev/null | grep -q "pw-ac3-live-input"; then
    log "pw-ac3-live-input found!"
    break
  fi
  if [ "$i" -eq 15 ]; then
    error "pw-ac3-live-input did not appear after 15s"
    cat "$PIPELINE_LOG" || true
    exit 1
  fi
  sleep 1
done

# ── 5. Generate and feed 6ch test tone via ffmpeg → pw-play ────────────
log "Feeding ${DURATION}s of 6ch sine waves→ pw-ac3-live-input..."

# Use ffmpeg to generate a continuous 6ch tone piped into pw-play.
# pw-play defaults to the default sink, which autoconnects via PipeWire.
ffmpeg -hide_banner -loglevel error -nostdin \
  -f lavfi -i "sine=frequency=440:duration=$DURATION" \
  -f lavfi -i "sine=frequency=880:duration=$DURATION" \
  -f lavfi -i "sine=frequency=1320:duration=$DURATION" \
  -f lavfi -i "sine=frequency=100:duration=$DURATION" \
  -f lavfi -i "sine=frequency=660:duration=$DURATION" \
  -f lavfi -i "sine=frequency=1100:duration=$DURATION" \
  -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
  -map "[a]" -ar "$SAMPLE_RATE" -f wav -y ci_test_6ch.wav 2>&1

pw-play ci_test_6ch.wav &
PLAY_PID=$!
sleep 1

# Link pw-play output to pw-ac3-live-input
log "Linking pw-play → pw-ac3-live-input..."
LINK_OK=false
for attempt in $(seq 1 20); do
  # Find the pw-play output ports by numeric ID
  mapfile -t FEEDER_IDS < <(pw-link -o -I 2> /dev/null | grep -i "pw-play" | awk '{print $1}' | sort -un)
  mapfile -t SINK_IDS < <(pw-link -i -I 2> /dev/null | grep "pw-ac3-live-input" | awk '{print $1}' | sort -un)

  if [ "${#FEEDER_IDS[@]}" -gt 0 ] && [ "${#SINK_IDS[@]}" -gt 0 ]; then
    local_max="${#FEEDER_IDS[@]}"
    if [ "${#SINK_IDS[@]}" -lt "$local_max" ]; then
      local_max="${#SINK_IDS[@]}"
    fi
    for ((i = 0; i < local_max; i++)); do
      pw-link "${FEEDER_IDS[$i]}" "${SINK_IDS[$i]}" 2> /dev/null || true
    done
    LINK_OK=true
    log "Linked ${local_max} port(s)."
    break
  fi
  sleep 0.5
done

if [ "$LINK_OK" = false ]; then
  warn "Could not link pw-play → pw-ac3-live-input (autoconnect may handle it)"
fi

# Wait for playback to finish
log "Waiting for playback to complete (${DURATION}s)..."
wait "$PLAY_PID" 2> /dev/null || true
PLAY_PID=""

# Give encoder buffers time to flush
sleep 2

# Stop pipeline
log "Stopping pw-ac3-live..."
kill "$PIPELINE_PID" 2> /dev/null || true
wait "$PIPELINE_PID" 2> /dev/null || true
PIPELINE_PID=""

# ── 6. Validate output ────────────────────────────────────────────────
log "Validating output..."

if [ ! -f "$OUTPUT_FILE" ]; then
  error "Output file $OUTPUT_FILE does not exist!"
  exit 1
fi

OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE")
if [ "$OUTPUT_SIZE" -eq 0 ]; then
  error "Output file is empty!"
  log "Pipeline log:"
  cat "$PIPELINE_LOG" || true
  exit 1
fi
log "Output size: $OUTPUT_SIZE bytes"

# Check frame alignment (must be multiple of 4 = 2ch × 2 bytes S16LE)
if [ $((OUTPUT_SIZE % 4)) -ne 0 ]; then
  error "Output is NOT frame-aligned (size $OUTPUT_SIZE is not a multiple of 4)"
  exit 1
fi
log "✓ Output is frame-aligned"

# Check for IEC 61937 preambles: Pa=0xF872, Pb=0x4E1F → LE bytes: 72 F8 1F 4E
PREAMBLE_COUNT=$(python3 -c "
data = open('$OUTPUT_FILE', 'rb').read()
count = sum(1 for i in range(len(data)-3) if data[i:i+4] == b'\x72\xf8\x1f\x4e')
print(count)
")

if [ "$PREAMBLE_COUNT" -eq 0 ]; then
  error "No IEC 61937 preambles found in output!"
  log "Pipeline log:"
  cat "$PIPELINE_LOG" || true
  exit 1
fi

log "✓ Found $PREAMBLE_COUNT IEC 61937 frame(s)"

# Optional: check frame spacing (AC-3 frames should be 6144 bytes apart)
if [ "$PREAMBLE_COUNT" -ge 2 ]; then
  SPACING_OK=$(python3 -c "
data = open('$OUTPUT_FILE', 'rb').read()
positions = [i for i in range(len(data)-3) if data[i:i+4] == b'\x72\xf8\x1f\x4e']
spacings = [positions[i+1]-positions[i] for i in range(len(positions)-1)]
bad = [s for s in spacings if s != 6144]
print(0 if bad else 1)
")
  if [ "$SPACING_OK" = "1" ]; then
    log "✓ All IEC 61937 frames are 6144 bytes apart"
  else
    warn "Some IEC 61937 frames have irregular spacing (may be acceptable in CI)"
  fi
fi

rm -f ci_test_6ch.wav

log ""
log "═══════════════════════════════════════"
log "  CI INTEGRATION TEST PASSED"
log "═══════════════════════════════════════"
