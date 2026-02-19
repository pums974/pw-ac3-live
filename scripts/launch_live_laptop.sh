#!/bin/bash
set -e

# Goal: Setup HDMI for AC3 passthrough and launch the encoder

LOW_LATENCY_BUFFER_SIZE="${PW_AC3_BUFFER_SIZE:-960}"
LOW_LATENCY_OUTPUT_BUFFER_SIZE="${PW_AC3_OUTPUT_BUFFER_SIZE:-}"
LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-64/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-16}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-64}"
ENABLE_LATENCY_PROFILE="${PW_AC3_PROFILE_LATENCY:-0}"

find_pw_ac3_live_sink_input_id() {
  pactl list sink-inputs | awk '
        /^Sink Input #/ { id = substr($3, 2); next }
        /^[[:space:]]*application.name = "pw-ac3-live"/ { print id; exit }
        /^[[:space:]]*Application Name: pw-ac3-live$/ { print id; exit }
    '
}

configure_hdmi_passthrough() {
  local sink_index="$1"

  echo "Configuring sink formats and volume..."
  if ! pactl set-sink-formats "$sink_index" 'ac3-iec61937, format.rate = "[ 48000 ]"'; then
    echo "Warning: Exact AC3 format string failed, retrying generic ac3-iec61937..."
    pactl set-sink-formats "$sink_index" "ac3-iec61937" || echo "Warning: Failed to set AC3 sink formats."
  fi

  pactl set-sink-volume "$sink_index" 100%
  pactl set-sink-mute "$sink_index" 0
}

normalize_pw_ac3_live_levels() {
  echo "Normalizing pw-ac3-live node/stream volumes..."

  pactl set-sink-volume "pw-ac3-live-input" 100% || true
  pactl set-sink-mute "pw-ac3-live-input" 0 || true

  local stream_id=""
  for _ in $(seq 1 20); do
    stream_id=$(find_pw_ac3_live_sink_input_id)
    if [ -n "$stream_id" ]; then
      pactl set-sink-input-volume "$stream_id" 100% || true
      pactl set-sink-input-mute "$stream_id" 0 || true
      echo "Set pw-ac3-live playback stream volume to 100% (sink-input #$stream_id)."
      return 0
    fi
    sleep 0.5
  done

  echo "Warning: Could not find pw-ac3-live playback sink-input; leaving stream volume unchanged."
}

# 0. Cleanup previous runs
echo "Stopping any existing instances..."
pkill -INT -f "pw-ac3-live" || true
sleep 1

# 1. Detect HDMI Card
echo "Detecting HDMI card..."
# We first find the card name to set profiles.
# Example: alsa_card.pci-0000_00_1f.3
CARD_NAME=$(pactl list cards short | grep "pci" | cut -f2 | head -n1)

if [ -z "$CARD_NAME" ]; then
  echo "Error: Could not automatically detect a PCI sound card."
  echo "Cards found:"
  pactl list cards short
  exit 1
fi
echo "Selected Card: $CARD_NAME"

# Extract the device identifier (e.g., pci-0000_00_1f.3) from the card name.
# This part is usually shared between card and sink names.
# Pattern: alsa_card.pci-XXXX... -> pci-XXXX...
# We just strip 'alsa_card.' prefix if present.
DEVICE_ID=$(echo "$CARD_NAME" | sed 's/^alsa_card\.//')
echo "Device ID: $DEVICE_ID"

# 2. Set Profile to HDMI Stereo
echo "Setting card profile..."
# Try to find the profile name from `pactl list cards`
# We look for a profile that is "output:hdmi-stereo" possibly with input tacked on.
# The user's system likely uses "output:hdmi-stereo+input:analog-stereo" or similar.
# Let's find any profile containing "output:hdmi-stereo" and use the first one.
# sed logic: range from Name: CARD to Active Profile, then find line with output:hdmi-stereo
PROFILE_NAME=$(pactl list cards | sed -n "/Name: $CARD_NAME/,/Active Profile/p" | grep "output:hdmi-stereo" | head -n1 | awk '{print $1}' | sed 's/:$//')

# If detection fails, we shouldn't just guess "output:hdmi-stereo" because it might need "+input:..."
# But if it's empty, we have to guess something or fail.
if [ -z "$PROFILE_NAME" ]; then
  echo "Warning: Could not find exact 'output:hdmi-stereo' profile."
  # A common fallback
  PROFILE_NAME="output:hdmi-stereo"
fi

echo "Using Profile: $PROFILE_NAME"
# Attempt to set it. capturing stderr to void if it fails? No, we want to see error.
if ! pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME"; then
  echo "Failed to set profile '$PROFILE_NAME'. Attempting to append '+input:analog-stereo'..."
  pactl set-card-profile "$CARD_NAME" "${PROFILE_NAME}+input:analog-stereo" || echo "Warning: Failed to set profile. Proceeding anyway."
fi

# 3. Find HDMI Sink Name
echo "Finding HDMI sink..."
# Now we search for a sink that contains the DEVICE_ID and "hdmi-stereo".
# Get the Name
SINK_NAME=$(pactl list sinks short | grep "$DEVICE_ID" | grep "hdmi-stereo" | cut -f2 | head -n1)
# Get the Index (1st column)
SINK_INDEX=$(pactl list sinks short | grep "$DEVICE_ID" | grep "hdmi-stereo" | cut -f1 | head -n1)

if [ -z "$SINK_NAME" ]; then
  echo "Error: Could not find HDMI stereo sink matching '$DEVICE_ID' and 'hdmi-stereo'."
  pactl list sinks short
  exit 1
fi
echo "Selected Sink: $SINK_NAME (Index: $SINK_INDEX)"

# 4. Configure Sink Formats (AC3 Passthrough) & Volume
configure_hdmi_passthrough "$SINK_INDEX"

# 5. Launch Application
echo "Launching pw-ac3-live..."
PROFILE_LATENCY_ARGS=()
if [ "$ENABLE_LATENCY_PROFILE" = "1" ]; then
  echo "Latency profiling enabled."
  PROFILE_LATENCY_ARGS+=(--profile-latency)
fi

OUTPUT_BUFFER_ARGS=()
if [ -n "$LOW_LATENCY_OUTPUT_BUFFER_SIZE" ]; then
  echo "Output buffer override: $LOW_LATENCY_OUTPUT_BUFFER_SIZE frames"
  OUTPUT_BUFFER_ARGS+=(--output-buffer-size "$LOW_LATENCY_OUTPUT_BUFFER_SIZE")
fi
# Run in background, assuming 'cargo' is in path.
# We use nohup or just backgrounding to keep it running?
# The user wants "one click", so maybe keep the terminal open or detach?
# If we run from terminal script, we probably want to see logs.
# Let's run it in foreground? No, the prompt implied we might want to do post-setup.
# So run in background, capture PID.
RUST_LOG=info cargo run --release -- --target "$SINK_NAME" \
  --buffer-size "$LOW_LATENCY_BUFFER_SIZE" \
  --latency "$LOW_LATENCY_NODE_LATENCY" \
  --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
  --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
  "${OUTPUT_BUFFER_ARGS[@]}" \
  "${PROFILE_LATENCY_ARGS[@]}" &
APP_PID=$!
echo "App launched with PID $APP_PID"

# 6. Wait for Nodes
echo "Waiting for pw-ac3-live-input node to appear..."
MAX_RETRIES=20
FOUND=0
for i in $(seq 1 $MAX_RETRIES); do
  if pw-link -i | grep -q "pw-ac3-live-input"; then
    FOUND=1
    break
  fi
  sleep 0.5
done

# Check input node (it's actually a sink, so it has input ports? No, it's a playback target, so it has input ports for apps)
# Wait, `pw-ac3-live-input` is a Virtual SINK. It has INPUT ports (audio comes IN).
# `pw-link -i` lists input ports.
if ! pw-link -i | grep -q "pw-ac3-live-input"; then
  echo "Warning: pw-ac3-live-input input ports not found yet. App might have failed starting."
fi

# 7. Set Default Sink
echo "Setting 'AC-3 Encoder Input' as default sink..."
# We need the ID for wpctl set-default.
# `pw-cli info match node.name=pw-ac3-live-input` or parsing `wpctl status`
# Simplest: use `pactl get-sink-volume` logic? No, `wpctl` is better for wireplumber defaults.
# Let's find the ID.
ENCODER_ID=$(wpctl status | grep "AC-3 Encoder Input" | grep -o "[0-9]\+" | head -n1) # This grep is risky on ID column
# Better way using pw-dump or pactl?
# `pactl get-default-sink` ?
# We can set default by NAME using pactl!
pactl set-default-sink "pw-ac3-live-input" || echo "Warning: Could not set default sink via pactl."

# 8. Ensure Link (Output -> HDMI)
echo "Ensuring encoder output is linked to HDMI..."
./scripts/connect.sh "$SINK_NAME"

# 9. Enforce bitstream-safe runtime levels after graph creation
normalize_pw_ac3_live_levels

echo "========================================"
echo "LAUNCH SUCCESSFUL"
echo "pw-ac3-live is running. Press SINK VOLUME warning: Ensure your physical receiver volume is strictly controlled!"
echo "Main logs are above. Press Ctrl+C to stop everything."
echo "========================================"

# Wait for the app to finish (so the script doesn't exit and kill the background job if the shell closes?)
# If the user runs this from a click, they might not see stdout.
# But for a script, usually we wait.
wait $APP_PID
