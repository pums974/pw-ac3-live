#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

# Configuration
DURATION=5
INPUT_FILE="test_input_6ch.wav"
OUTPUT_FILE="output.spdif"
SAMPLE_RATE=48000
CHANNELS=6
SINK_NAME="pw-ac3-test-sink"
INTERMEDIATE_FILE="intermediate.raw"
PIPELINE_LOG="pw-ac3-live-pipeline.log"
RECORD_LOG="pw-record-local.log"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[TEST]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

MODULE_ID=""
DEFAULT_SINK=""
PIPELINE_PID=""
RECORD_PID=""
PLAY_PID=""

stop_recorder() {
  if [ -z "$RECORD_PID" ]; then
    return
  fi

  if kill -0 "$RECORD_PID" 2> /dev/null; then
    kill -INT "$RECORD_PID" 2> /dev/null || true
    for _ in {1..20}; do
      if ! kill -0 "$RECORD_PID" 2> /dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$RECORD_PID" 2> /dev/null; then
      kill "$RECORD_PID" 2> /dev/null || true
    fi
    wait "$RECORD_PID" 2> /dev/null || true
  fi

  RECORD_PID=""
}

cleanup() {
  log "Cleaning up..."

  if [ -n "$PLAY_PID" ] && kill -0 "$PLAY_PID" 2> /dev/null; then
    kill "$PLAY_PID" 2> /dev/null || true
    wait "$PLAY_PID" 2> /dev/null || true
  fi

  stop_recorder

  if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2> /dev/null; then
    # Kill the whole process group (daemon + tee + pw-play).
    kill -- "-$PIPELINE_PID" 2> /dev/null || true
    wait "$PIPELINE_PID" 2> /dev/null || true
  fi

  if [ -n "$DEFAULT_SINK" ]; then
    log "Restoring default sink to $DEFAULT_SINK..."
    pactl set-default-sink "$DEFAULT_SINK" || true
  fi

  if [ -n "$MODULE_ID" ]; then
    log "Unloading null sink (module $MODULE_ID)..."
    pactl unload-module "$MODULE_ID" || true
  fi
}
trap cleanup EXIT

# 1. Check Dependencies
log "Checking dependencies..."
command -v cargo > /dev/null 2>&1 || {
  error "cargo not found"
  exit 1
}
command -v ffmpeg > /dev/null 2>&1 || {
  error "ffmpeg not found"
  exit 1
}
command -v pw-play > /dev/null 2>&1 || {
  error "pw-play not found"
  exit 1
}
command -v pw-record > /dev/null 2>&1 || {
  error "pw-record not found"
  exit 1
}
command -v pactl > /dev/null 2>&1 || {
  error "pactl not found (required for dummy driver)"
  exit 1
}

# Ensure we don't validate stale artifacts from previous runs.
rm -f "$OUTPUT_FILE" "$INTERMEDIATE_FILE" "$PIPELINE_LOG" "$RECORD_LOG"

# 2. Build the project
log "Building pw-ac3-live..."
cargo build --release

# 3. Create Dummy Sink (Driver)
log "Creating null sink '$SINK_NAME' to drive the graph..."
# Force S16LE format to match pw-ac3-live output expectation
MODULE_ID=$(pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="AC3_Test_Sink" format=s16le rate=48000 channels=2)
if [ -z "$MODULE_ID" ]; then
  error "Failed to load module-null-sink"
  exit 1
fi
log "Loaded module $MODULE_ID"
sleep 1 # Give it a moment to appear

# Debug: Check if sink exists and get its name/ID
log "Inspecting generated sink:"
pw-cli info all | grep "$SINK_NAME" || log "WARNING: $SINK_NAME not found in pw-cli info"
pw-link -o | grep "$SINK_NAME" || true
pw-link -i | grep "$SINK_NAME" || true

# 4. Verify Sink Usability
log "Verifying sink '$SINK_NAME' with pw-play..."
# Generate short stereo beep
ffmpeg -y -f lavfi -i "sine=frequency=1000:duration=0.5" -ar 48000 -ac 2 test_beep.wav -loglevel error
if pw-play --target "$SINK_NAME" test_beep.wav; then
  log "Sink verification successful."
else
  error "Sink verification failed! pw-play could not play to $SINK_NAME"
  exit 1
fi

# 5. Generate Test Audio (if not exists)
if [ ! -f "$INPUT_FILE" ]; then

  log "Generating $DURATION second 6-channel test file..."
  # Generate 6 distinct sine waves:
  # FL: 440, FR: 880, FC: 1320, LFE: 100, BL: 660, BR: 1100
  ffmpeg -y -f lavfi -i "sine=frequency=440:duration=$DURATION" \
    -f lavfi -i "sine=frequency=880:duration=$DURATION" \
    -f lavfi -i "sine=frequency=1320:duration=$DURATION" \
    -f lavfi -i "sine=frequency=100:duration=$DURATION" \
    -f lavfi -i "sine=frequency=660:duration=$DURATION" \
    -f lavfi -i "sine=frequency=1100:duration=$DURATION" \
    -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
    -map "[a]" -ar $SAMPLE_RATE "$INPUT_FILE"
fi

# 5. Setup Default Sink (Fallback for targeting issues)
log "Saving current default sink..."
DEFAULT_SINK=$(pactl get-default-sink)
log "Current default: $DEFAULT_SINK"

log "Setting default sink to $SINK_NAME..."
pactl set-default-sink "$SINK_NAME"

# 6. Start the Daemon
log "Starting pw-ac3-live in STDOUT mode..."
# Run daemon/stdout pipeline in its own process group for robust cleanup.
setsid bash -c '
set -euo pipefail
RUST_LOG=info ./target/release/pw-ac3-live --stdout \
  | tee "$1" \
  | pw-play --target "$2" --raw --format s16 --rate 48000 --channels 2 -
' _ "$INTERMEDIATE_FILE" "$SINK_NAME" > "$PIPELINE_LOG" 2>&1 &
PIPELINE_PID=$!
sleep 2 # Wait for startup

# Check if pipeline is running
if ! kill -0 "$PIPELINE_PID" 2> /dev/null; then
  error "Daemon pipeline failed to start. Recent logs:"
  tail -n 40 "$PIPELINE_LOG" || true
  exit 1
fi

# Debug links (pw-play should have created a stream connected to sink)
log "Check connections:"
pw-link -l | grep pw-play || true

# Wait for pw-ac3-live-input to appear
log "Waiting for pw-ac3-live-input..."
for i in {1..10}; do
  if pw-link -i | grep -q "pw-ac3-live-input"; then
    log "pw-ac3-live-input found!"
    break
  fi
  sleep 1
done

# 7. Start Recording (from sink monitor path)
log "Starting recorder on $SINK_NAME monitor capture..."
# Force raw stream to stdout and redirect it into OUTPUT_FILE.
pw-record --target "$SINK_NAME" -P stream.capture.sink=true --raw --format s16 --rate "$SAMPLE_RATE" --channels 2 - > "$OUTPUT_FILE" 2> "$RECORD_LOG" &
RECORD_PID=$!
sleep 0.5
if ! kill -0 "$RECORD_PID" 2> /dev/null; then
  error "pw-record failed to start. Recent recorder logs:"
  tail -n 40 "$RECORD_LOG" || true
  exit 1
fi

# 8. Play the test file
log "Playing test audio to pw-ac3-live-input..."
# Start pw-play without target (0), set node.name via properties
pw-play --target 0 -P 'node.name=pw-ac3-feeder' "$INPUT_FILE" > pw-play-input.log 2>&1 &
PLAY_PID=$!

# Wait for player to appear
sleep 1
log "Linking pw-ac3-feeder to pw-ac3-live-input..."

# Debug available ports
log "Feeder output ports:"
pw-link -o | grep pw-ac3-feeder || true
log "Input sink ports (full dump to ports.log):"
pw-link -i > ports.log
grep "pw-ac3-live-input" ports.log || true

# Inspect pw-ac3-live-input properties
INPUT_NODE_ID=$(pw-link -i | grep "pw-ac3-live-input" | head -n 1 | cut -d: -f1)
if [ ! -z "$INPUT_NODE_ID" ]; then
  log "Inspecting pw-ac3-live-input (ID: $INPUT_NODE_ID)..."
  pw-cli info "$INPUT_NODE_ID"
else
  log "Assuming pw-ac3-live-input ID not found directly, trying to grep name"
fi

# Helper to link by ID
link_ports_by_id() {
  mapfile -t FEEDER_IDS < <(pw-link -o -I | grep "pw-ac3-feeder" | awk '{print $1}' | sort -un)
  mapfile -t SINK_IDS < <(pw-link -i -I | grep "pw-ac3-live-input" | awk '{print $1}' | sort -un)

  log "Feeder IDs: ${FEEDER_IDS[*]:-<none>}"
  log "Sink IDs: ${SINK_IDS[*]:-<none>}"

  if [ "${#FEEDER_IDS[@]}" -eq 0 ] || [ "${#SINK_IDS[@]}" -eq 0 ]; then
    log "Error: Could not find ports to link."
    return
  fi

  local max_links="${#FEEDER_IDS[@]}"
  if [ "${#SINK_IDS[@]}" -lt "$max_links" ]; then
    max_links="${#SINK_IDS[@]}"
  fi

  # Interleaved nodes often expose one port; link all feeder ports to sink[0] in that case.
  if [ "${#SINK_IDS[@]}" -eq 1 ]; then
    local dst="${SINK_IDS[0]}"
    for src in "${FEEDER_IDS[@]}"; do
      log "Linking ID $src -> $dst"
      pw-link --wait "$src" "$dst" || log "Link failed (already linked/incompatible): $src -> $dst"
    done
    return
  fi

  local i
  for ((i = 0; i < max_links; i++)); do
    local src="${FEEDER_IDS[$i]}"
    local dst="${SINK_IDS[$i]}"
    log "Linking ID $src -> $dst"
    pw-link --wait "$src" "$dst" || log "Link failed (already linked/incompatible): $src -> $dst"
  done
}

link_ports_by_id

# Diagnose connections while playing
sleep 1
log "Active Links during playback:"
pw-link -l | grep -E "pw-ac3|Sine" || true

# Wait for playback to finish
wait $PLAY_PID || true

# Check pw-play log if failed
if [ -s pw-play-input.log ]; then
  log "pw-play output:"
  cat pw-play-input.log
fi

# Wait a bit for buffers to flush
sleep 1

# Stop recorder before verifying to avoid races on file size/content.
stop_recorder

# Stop pipeline before verifying and analysis.
if [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2> /dev/null; then
  kill -- "-$PIPELINE_PID" 2> /dev/null || true
  wait "$PIPELINE_PID" 2> /dev/null || true
fi
PIPELINE_PID=""

# 9. Verification
log "Verifying output..."
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
  log "Output file created successfully."
  ls -lh "$OUTPUT_FILE"

  # Optional: Analyze with ffprobe
  # log "Analyzing output with ffprobe..."
  # ffprobe -hide_banner "$OUTPUT_FILE" || true

  # [NEW] Verify IEC61937 Preamble
  # We look for the "Pa" preamble: 0xF872 (Little Endian: 0x72 0xF8)
  # This confirms the presence of encoded data packets.
  log "Analyzing output for IEC61937 headers..."

  python3 -c "
import sys
import os

def check_iec(filename, required):
    print(f'Checking {filename}...')
    try:
        with open(filename, 'rb') as f:
            data = f.read()
            # Search for full IEC61937 preamble sequence:
            # Pa=0xF872 + Pb=0x4E1F (LE bytes: 72 F8 1F 4E)
            count = 0
            for i in range(0, len(data)-3):
                if data[i:i+4] == b'\x72\xf8\x1f\x4e':
                    count += 1

            if count > 0:
                print(f'SUCCESS: Found {count} IEC61937 frames (AC-3 Encapsulated).')
                return True
            else:
                if required:
                    print('FAILURE: No IEC61937 preamble found. Output might be raw PCM or silence.')
                else:
                    print('WARNING: No IEC61937 preamble found (expected after sink mixing/conversion).')
                return not required
    except Exception as e:
        print(f'Error analyzing file: {e}')
        return not required

ok = check_iec('$OUTPUT_FILE', required=False)

if os.path.exists('$INTERMEDIATE_FILE'):
    ok = check_iec('$INTERMEDIATE_FILE', required=True) and ok

if not ok:
    sys.exit(1)
"
else
  error "Output file is missing or empty!"
  if [ -f "$RECORD_LOG" ] && [ -s "$RECORD_LOG" ]; then
    log "Recent recorder logs:"
    tail -n 40 "$RECORD_LOG"
  fi
  if [ -f "$PIPELINE_LOG" ] && [ -s "$PIPELINE_LOG" ]; then
    log "Recent pipeline logs:"
    tail -n 40 "$PIPELINE_LOG"
  fi
  exit 1
fi

log "Test complete!"
