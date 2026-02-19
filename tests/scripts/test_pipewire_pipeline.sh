#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

# Configuration
DURATION=5
INPUT_FILE="test_input_6ch.wav"
OUTPUT_FILE="output_pipewire.spdif"
SAMPLE_RATE=48000
SINK_NAME="pw-ac3-test-sink"
RECORD_LOG="pw-record-native.log"

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
DAEMON_PID=""
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

  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2> /dev/null; then
    kill "$DAEMON_PID" 2> /dev/null || true
    wait "$DAEMON_PID" 2> /dev/null || true
  fi

  if [ -n "$MODULE_ID" ]; then
    log "Unloading null sink (module $MODULE_ID)..."
    pactl unload-module "$MODULE_ID" || true
  fi
}
trap cleanup EXIT

wait_for_pw_port() {
  local description="$1"
  local list_flag="$2"
  local pattern="$3"

  log "Waiting for $description..."
  for _ in {1..20}; do
    if pw-link "$list_flag" | grep -q "$pattern"; then
      log "$description found!"
      return 0
    fi
    sleep 0.5
  done

  error "Timed out waiting for $description"
  pw-link "$list_flag" || true
  return 1
}

connect_output_to_sink() {
  mapfile -t output_ports < <(pw-link -o | grep "pw-ac3-live-output" | awk '{print $1}' | sort -u)
  mapfile -t sink_ports < <(pw-link -i | grep "$SINK_NAME" | grep "playback" | awk '{print $1}' | sort -u)

  log "Output Ports: ${output_ports[*]:-<none>}"
  log "Sink Ports: ${sink_ports[*]:-<none>}"

  if [ "${#output_ports[@]}" -eq 0 ] || [ "${#sink_ports[@]}" -eq 0 ]; then
    error "Could not find output/sink ports for linking."
    pw-link -o || true
    pw-link -i || true
    return 1
  fi

  for idx in "${!sink_ports[@]}"; do
    local src_idx=0
    if [ "${#output_ports[@]}" -gt 1 ]; then
      if [ "$idx" -ge "${#output_ports[@]}" ]; then
        break
      fi
      src_idx="$idx"
    fi

    local src="${output_ports[$src_idx]}"
    local dst="${sink_ports[$idx]}"
    log "Linking $src -> $dst"
    pw-link --wait "$src" "$dst" || log "Link failed for $src -> $dst (already linked?)"
  done
}

connect_feeder_to_input() {
  mapfile -t feeder_ports < <(pw-link -o -I | grep "pw-ac3-feeder" | awk '{print $1}' | sort -un)
  mapfile -t input_ports < <(pw-link -i -I | grep "pw-ac3-live-input" | awk '{print $1}' | sort -un)

  log "Feeder Ports: ${feeder_ports[*]:-<none>}"
  log "Input Ports: ${input_ports[*]:-<none>}"

  if [ "${#feeder_ports[@]}" -eq 0 ] || [ "${#input_ports[@]}" -eq 0 ]; then
    error "Could not find feeder/input ports for linking."
    pw-link -o | grep "pw-ac3" || true
    pw-link -i | grep "pw-ac3" || true
    return 1
  fi

  if [ "${#input_ports[@]}" -eq 1 ]; then
    local dst="${input_ports[0]}"
    for src in "${feeder_ports[@]}"; do
      log "Linking $src -> $dst"
      pw-link --wait "$src" "$dst" || log "Link failed for $src -> $dst (already linked?)"
    done
    return 0
  fi

  local max_links="${#feeder_ports[@]}"
  if [ "${#input_ports[@]}" -lt "$max_links" ]; then
    max_links="${#input_ports[@]}"
  fi

  local i
  for ((i = 0; i < max_links; i++)); do
    local src="${feeder_ports[$i]}"
    local dst="${input_ports[$i]}"
    log "Linking $src -> $dst"
    pw-link --wait "$src" "$dst" || log "Link failed for $src -> $dst (already linked?)"
  done
}

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
rm -f "$OUTPUT_FILE" "$RECORD_LOG"

# 2. Build the project
log "Building pw-ac3-live..."
cargo build --release

# 3. Create Dummy Sink (Driver)
log "Creating null sink '$SINK_NAME' to drive the graph..."
MODULE_ID=$(pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="AC3_Test_Sink" format=s16le rate=48000 channels=2)
if [ -z "$MODULE_ID" ]; then
  error "Failed to load module-null-sink"
  exit 1
fi
log "Loaded module $MODULE_ID"
sleep 1

log "Inspecting generated sink:"
pw-cli info all | grep "$SINK_NAME" || log "WARNING: $SINK_NAME not found in pw-cli info"
pw-link -o | grep "$SINK_NAME" || true
pw-link -i | grep "$SINK_NAME" || true

# 4. Verify Sink Usability
log "Verifying sink '$SINK_NAME' with pw-play..."
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
  ffmpeg -y -f lavfi -i "sine=frequency=440:duration=$DURATION" \
    -f lavfi -i "sine=frequency=880:duration=$DURATION" \
    -f lavfi -i "sine=frequency=1320:duration=$DURATION" \
    -f lavfi -i "sine=frequency=100:duration=$DURATION" \
    -f lavfi -i "sine=frequency=660:duration=$DURATION" \
    -f lavfi -i "sine=frequency=1100:duration=$DURATION" \
    -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
    -map "[a]" -ar "$SAMPLE_RATE" "$INPUT_FILE"
fi

# 6. Start daemon in native PipeWire mode
log "Starting pw-ac3-live in NATIVE PipeWire mode..."
RUST_LOG=info ./target/release/pw-ac3-live --target "$SINK_NAME" &
DAEMON_PID=$!
sleep 2

if ! kill -0 "$DAEMON_PID" 2> /dev/null; then
  error "Daemon failed to start"
  exit 1
fi

wait_for_pw_port "pw-ac3-live-input" "-i" "pw-ac3-live-input"
wait_for_pw_port "pw-ac3-live-output" "-o" "pw-ac3-live-output"

log "Linking pw-ac3-live-output to $SINK_NAME..."
connect_output_to_sink

# 7. Start recording directly from output node
log "Starting recorder on pw-ac3-live-output..."
# Force raw stream to stdout and redirect it into OUTPUT_FILE.
pw-record --target "pw-ac3-live-output" --raw --format s16 --rate "$SAMPLE_RATE" --channels 2 - > "$OUTPUT_FILE" 2> "$RECORD_LOG" &
RECORD_PID=$!
sleep 0.5
if ! kill -0 "$RECORD_PID" 2> /dev/null; then
  error "pw-record failed to start. Recent recorder logs:"
  tail -n 40 "$RECORD_LOG" || true
  exit 1
fi

# 8. Play test audio via feeder, then link feeder -> pw-ac3-live-input
log "Playing test audio via pw-ac3-feeder..."
pw-play --target 0 -P 'node.name=pw-ac3-feeder' "$INPUT_FILE" > pw-play-input.log 2>&1 &
PLAY_PID=$!

sleep 1
log "Linking pw-ac3-feeder to pw-ac3-live-input..."
connect_feeder_to_input

wait "$PLAY_PID" || true
PLAY_PID=""

if [ -s pw-play-input.log ]; then
  log "pw-play output:"
  cat pw-play-input.log
fi

sleep 1

log "Active Links:"
pw-link -l | grep "pw-ac3" || true

stop_recorder

# 9. Verification
log "Verifying output..."
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
  log "Output file created successfully."
  ls -lh "$OUTPUT_FILE"

  log "Analyzing output for IEC61937 headers..."
  python3 -c "
import sys

def check_iec(filename):
    print(f'Checking {filename}...')
    with open(filename, 'rb') as f:
        data = f.read()
    count = 0
    for i in range(0, len(data) - 3):
        if data[i:i+4] == b'\x72\xf8\x1f\x4e':
            count += 1
    if count > 0:
        print(f'SUCCESS: Found {count} IEC61937 frames (AC-3 Encapsulated).')
    else:
        print('FAILURE: No IEC61937 preamble found. Output might be raw PCM or silence.')
        sys.exit(1)

check_iec('$OUTPUT_FILE')
"
else
  error "Output file is missing or empty!"
  if [ -f "$RECORD_LOG" ] && [ -s "$RECORD_LOG" ]; then
    log "Recent recorder logs:"
    tail -n 40 "$RECORD_LOG"
  fi
  exit 1
fi

log "Test complete!"
