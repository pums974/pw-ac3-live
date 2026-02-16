#!/bin/bash
set -e

# Goal: Setup HDMI for AC3 passthrough and launch the encoder

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOW_LATENCY_BUFFER_SIZE="${PW_AC3_BUFFER_SIZE:-960}"
LOW_LATENCY_OUTPUT_BUFFER_SIZE="${PW_AC3_OUTPUT_BUFFER_SIZE:-}"
LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-64/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-32}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-128}"
ENABLE_LATENCY_PROFILE="${PW_AC3_PROFILE_LATENCY:-0}"
TARGET_SINK_OVERRIDE="${PW_AC3_TARGET_SINK:-}"
APP_BIN="${ROOT_DIR}/bin/pw-ac3-live"
DEV_BIN="${ROOT_DIR}/target/release/pw-ac3-live"
USE_PACKAGED_BINARY=0

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

move_existing_streams_to_encoder_input() {
    echo "Moving existing app streams to 'AC-3 Encoder Input'..."
    local encoder_stream_id=""
    encoder_stream_id=$(find_pw_ac3_live_sink_input_id || true)

    while read -r stream_id _; do
        [ -z "$stream_id" ] && continue
        if [ -n "$encoder_stream_id" ] && [ "$stream_id" = "$encoder_stream_id" ]; then
            continue
        fi
        if pactl move-sink-input "$stream_id" "pw-ac3-live-input" >/dev/null 2>&1; then
            echo "Moved sink-input #$stream_id to pw-ac3-live-input."
        fi
    done < <(pactl list sink-inputs short)
}

find_best_hdmi_sink_line() {
    pactl list sinks short | awk '
        BEGIN { best_score = -100000 }
        $2 ~ /hdmi/ {
            name = $2
            score = 0

            if (name ~ /^alsa_output\./) score += 100
            if (name ~ /pci-/) score += 20
            if (name ~ /hdmi-stereo/) score += 10
            if ($NF == "RUNNING") score += 5

            if (name ~ /^alsa_loopback_device\./) score -= 300
            if (name ~ /loopback/) score -= 300
            if (name ~ /pw-ac3-live/) score -= 300
            if (name ~ /monitor/) score -= 150

            if (score > best_score) {
                best_score = score
                best_line = $0
            }
        }
        END {
            if (best_line != "") {
                print best_line
            }
        }
    '
}

# 0. Cleanup previous runs
echo "Stopping any existing instances..."
pkill -INT -f "pw-ac3-live" || true
sleep 1
# 1. Detect HDMI sink (prefer physical ALSA output; allow manual override)
echo "Finding HDMI sink..."
if [ -n "$TARGET_SINK_OVERRIDE" ]; then
  echo "Using PW_AC3_TARGET_SINK override: $TARGET_SINK_OVERRIDE"
  HDMI_LINE=$(pactl list sinks short | awk -v sink="$TARGET_SINK_OVERRIDE" '$2==sink {print; exit}')
else
  HDMI_LINE=$(find_best_hdmi_sink_line)
fi

if [ -z "$HDMI_LINE" ]; then
  echo "Error: No HDMI sink found."
  pactl list sinks short
  exit 1
fi

SINK_INDEX=$(echo "$HDMI_LINE" | awk '{print $1}')
SINK_NAME=$(echo "$HDMI_LINE"  | awk '{print $2}')
echo "Selected Sink: $SINK_NAME (Index: $SINK_INDEX)"

if echo "$SINK_NAME" | grep -q "loopback"; then
  echo "Warning: Selected sink appears to be loopback-based. Passthrough may be silent."
  echo "Hint: export PW_AC3_TARGET_SINK=<physical alsa_output...hdmi-stereo sink>"
fi

# 2. Get the card index backing that sink, then card name
CARD_INDEX=$(
  pactl list sinks | awk -v s="$SINK_NAME" '
    $1=="Name:" && $2==s {found=1; next}
    found && $1=="Card:" {print $2; exit}
    found && $1=="Name:" && $2!=s {exit}
  '
)

if [ -z "$CARD_INDEX" ]; then
  DERIVED_CARD_NAME=$(echo "$SINK_NAME" | sed 's/^alsa_output\./alsa_card./; s/\.hdmi.*$//')
  if [ -n "$DERIVED_CARD_NAME" ]; then
    CARD_INDEX=$(pactl list cards short | awk -v n="$DERIVED_CARD_NAME" '$2==n {print $1; exit}')
    if [ -n "$CARD_INDEX" ]; then
      echo "Derived card from sink name: $DERIVED_CARD_NAME (Index: $CARD_INDEX)"
    fi
  fi
fi

if [ -z "$CARD_INDEX" ]; then
  echo "Warning: Could not determine card index for sink; skipping profile set."
  CARD_NAME=""
else
  CARD_NAME=$(pactl list cards short | awk -v id="$CARD_INDEX" '$1==id {print $2; exit}')
  echo "Selected Card: $CARD_NAME (Index: $CARD_INDEX)"
fi

# 3. Try to set a matching HDMI profile (optional; do not hard-fail)
if [ -n "$CARD_NAME" ]; then
  # Extract device.profile.name from the sink, e.g. "hdmi-stereo-extra2"
  PROFILE_SUFFIX=$(
    pactl list sinks | awk -v s="$SINK_NAME" '
      $1=="Name:" && $2==s {found=1}
      found && $0 ~ /device\.profile\.name/ {
        # last field is usually "hdmi-stereo-extraX" in quotes
        gsub(/"/,"",$NF); print $NF; exit
      }
    '
  )

  if [ -n "$PROFILE_SUFFIX" ]; then
    # Find an exact profile token on that card containing output:<suffix>
    PROFILE_NAME=$(
      pactl list cards | sed -n "/Name: $CARD_NAME/,/Active Profile/p" \
        | awk -v suf="$PROFILE_SUFFIX" '$1 ~ ("output:"suf) {gsub(/:$/,"",$1); print $1; exit}'
    )

    # Fallback
    [ -z "$PROFILE_NAME" ] && PROFILE_NAME="output:$PROFILE_SUFFIX"

    echo "Setting card profile: $PROFILE_NAME"
    pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME" || \
      echo "Warning: Failed to set card profile; continuing."
  else
    echo "Warning: Could not read device.profile.name; skipping profile set."
  fi
fi

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

if [ -x "$APP_BIN" ]; then
    echo "Using packaged binary: $APP_BIN"
    USE_PACKAGED_BINARY=1
elif [ -x "$DEV_BIN" ]; then
    echo "Using local release binary: $DEV_BIN"
else
    if ! command -v cargo >/dev/null 2>&1; then
        echo "Error: No packaged/release binary found and 'cargo' is not installed."
        echo "Expected one of:"
        echo "  $APP_BIN"
        echo "  $DEV_BIN"
        exit 1
    fi
    echo "No prebuilt binary found, falling back to cargo run --release."
fi

if [ "$USE_PACKAGED_BINARY" = "1" ]; then
    RUST_LOG=info "$APP_BIN" \
        --target "$SINK_NAME" \
        --buffer-size "$LOW_LATENCY_BUFFER_SIZE" \
        --latency "$LOW_LATENCY_NODE_LATENCY" \
        --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
        --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
        "${OUTPUT_BUFFER_ARGS[@]}" \
        "${PROFILE_LATENCY_ARGS[@]}" &
elif [ -x "$DEV_BIN" ]; then
    RUST_LOG=info "$DEV_BIN" \
        --target "$SINK_NAME" \
        --buffer-size "$LOW_LATENCY_BUFFER_SIZE" \
        --latency "$LOW_LATENCY_NODE_LATENCY" \
        --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
        --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
        "${OUTPUT_BUFFER_ARGS[@]}" \
        "${PROFILE_LATENCY_ARGS[@]}" &
else
    RUST_LOG=info cargo run --release -- \
        --target "$SINK_NAME" \
        --buffer-size "$LOW_LATENCY_BUFFER_SIZE" \
        --latency "$LOW_LATENCY_NODE_LATENCY" \
        --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
        --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
        "${OUTPUT_BUFFER_ARGS[@]}" \
        "${PROFILE_LATENCY_ARGS[@]}" &
fi
APP_PID=$!
echo "App launched with PID $APP_PID"

# 6. Wait for Nodes
echo "Waiting for pw-ac3-live-input node to appear..."
MAX_RETRIES=20
for _ in $(seq 1 "$MAX_RETRIES"); do
    if pw-link -i | grep -q "pw-ac3-live-input"; then
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
pactl set-default-sink "pw-ac3-live-input" || echo "Warning: Could not set default sink via pactl."
if command -v wpctl >/dev/null 2>&1; then
    ENCODER_ID=$(wpctl status | awk '
      /AC-3 Encoder Input/ {
        if (match($0, /[0-9]+/)) {
          print substr($0, RSTART, RLENGTH)
          exit
        }
      }
    ')
    if [ -n "$ENCODER_ID" ]; then
        wpctl set-default "$ENCODER_ID" || echo "Warning: Could not set default sink via wpctl."
    else
        echo "Warning: Could not find AC-3 Encoder Input ID in wpctl status; skipping wpctl default set."
    fi
else
    echo "Warning: wpctl not found; skipping wpctl default set."
fi

# Re-route already-running app streams that might still be pinned to old sinks.
move_existing_streams_to_encoder_input

# 8. Ensure Link (Output -> HDMI)
echo "Ensuring encoder output is linked to HDMI..."
"${SCRIPT_DIR}/connect.sh" "$SINK_NAME"

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
