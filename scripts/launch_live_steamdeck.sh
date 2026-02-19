#!/bin/bash
set -e

# Goal: Setup HDMI for AC3 passthrough and launch the encoder on Steam Deck
# Simplified version: Hardcoded for Steam Deck hardware

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Application Binary
APP_BIN="${ROOT_DIR}/bin/pw-ac3-live"

# Latency Tuning
LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-1536/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-4}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-1536}"

# Hardware Specifics (Steam Deck)
DIRECT_ALSA_DEVICE="hw:0,8"
LOOPBACK_SINK_NAME="alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2"
CARD_NAME="alsa_card.pci-0000_04_00.1"
ALSA_CARD_INDEX=0
IEC958_INDEX=2

# Direct ALSA parameters
DIRECT_ALSA_BUFFER_TIME="${PW_AC3_DIRECT_ALSA_BUFFER_TIME:-60000}"
DIRECT_ALSA_PERIOD_TIME="${PW_AC3_DIRECT_ALSA_PERIOD_TIME:-15000}"

# State variables
CLEANUP_DONE=0
APP_PID=""

# ------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------

find_pw_ac3_live_sink_input_id() {
    pactl list sink-inputs | awk '
        /^Sink Input #/ { id = substr($3, 2); next }
        /^[[:space:]]*application.name = "pw-ac3-live"/ { print id; exit }
        /^[[:space:]]*Application Name: pw-ac3-live$/ { print id; exit }
    '
}

mute_internal_output() {
    echo "Temporary muting internal audio to avoid startup noise..."
    # Mute current default sink
    pactl set-sink-mute @DEFAULT_SINK@ 1 >/dev/null 2>&1 || true

    # Mute known internal speaker sinks (nau8821, Speaker, Headphones)
    pactl list sinks short | awk '/Speaker|Headphones|nau8821/ {print $2}' | while read -r sink; do
        pactl set-sink-mute "$sink" 1 >/dev/null 2>&1 || true
    done
}

unmute_internal_output() {
    echo "Restoring internal audio volume..."
    # Unmute known internal speaker sinks
    pactl list sinks short | awk '/Speaker|Headphones|nau8821/ {print $2}' | while read -r sink; do
        pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true
    done
    # Unmute loopback sink if present
    pactl set-sink-mute "$LOOPBACK_SINK_NAME" 0 >/dev/null 2>&1 || true
    # Unmute default sink
    pactl set-sink-mute @DEFAULT_SINK@ 0 >/dev/null 2>&1 || true
}

restore_audio_state() {
    # Restore the card profile to ensure HDMI audio works for other apps after exit
    local restore_profile="output:hdmi-stereo-extra2"
    
    if [ -n "$CARD_NAME" ]; then
        if pactl set-card-profile "$CARD_NAME" "$restore_profile" >/dev/null 2>&1; then
            echo "Restored card profile: $restore_profile"
        else
            echo "Warning: Failed to restore card profile '$restore_profile' on '$CARD_NAME'."
        fi
    fi

    # Restore default sink to the loopback device
    if pactl set-default-sink "$LOOPBACK_SINK_NAME" >/dev/null 2>&1; then
        echo "Restored default sink: $LOOPBACK_SINK_NAME"
        pactl set-sink-mute "$LOOPBACK_SINK_NAME" 0 >/dev/null 2>&1 || true
    else
        echo "Warning: Failed to restore default sink '$LOOPBACK_SINK_NAME'."
    fi
}

cleanup() {
    local message="$1"

    if [ "$CLEANUP_DONE" = "1" ]; then
        return 0
    fi
    CLEANUP_DONE=1

    if [ -n "$message" ]; then
        echo "$message"
    fi
    
    # Restore IEC958 status to "audio" (PCM) to prevent "Zombie State"
    if command -v iecset >/dev/null 2>&1; then
        echo "Restoring IEC958 status to 'audio' on index $IEC958_INDEX..."
        iecset -c "$ALSA_CARD_INDEX" -n "$IEC958_INDEX" audio on >/dev/null 2>&1 || true
    fi

    # 1. Re-mute internal speakers to be sure
    mute_internal_output

    # 2. Restore global state (Loopback Sink + HDMI Profile)
    restore_audio_state
    
    # 3. Explicitly move streams to the loopback sink BEFORE killing the app
    #    This prevents them from falling back to internal speakers when the app dies.
    echo "Moving streams back to loopback sink..."
    pactl list sink-inputs short | while read -r stream_id _; do
        pactl move-sink-input "$stream_id" "$LOOPBACK_SINK_NAME" >/dev/null 2>&1 || true
    done

    # 4. Kill the app
    if [ -n "$APP_PID" ]; then
         echo "Killing app PID $APP_PID and children..."
         pkill -P $$ >/dev/null 2>&1 || true
         kill "$APP_PID" >/dev/null 2>&1 || true
    fi

    # 5. Unmute everything
    unmute_internal_output
}

# ------------------------------------------------------------------
# MAIN LOGIC
# ------------------------------------------------------------------

# 0. Cleanup previous runs
echo "Stopping any existing instances..."
pkill -INT -f "pw-ac3-live" || true
# Unload any previously loaded direct ALSA sink module
pactl list short modules | grep "sink_name=pw_ac3_direct_hdmi" | cut -f1 | xargs -r -I{} pactl unload-module {} >/dev/null 2>&1 || true

# 1. Validation Setup
if ! command -v aplay >/dev/null 2>&1; then
    echo "Error: 'aplay' not found. Cannot proceed."
    exit 1
fi
if ! command -v iecset >/dev/null 2>&1; then
    echo "Warning: 'iecset' not found. Cannot force IEC958 status."
fi

# 2. Direct ALSA Launch Strategy
# ------------------------------
# PipeWire locks the IEC958 controls (rw--l---) while the card profile is active.
# We must disable the profile, then use 'iecset', then launch 'aplay'.

# STEP 1: Mute internal speakers to prevent pop/noise during switch
mute_internal_output

echo "Disabling card profile '$CARD_NAME' to release ALSA device..."
pactl set-card-profile "$CARD_NAME" off >/dev/null 2>&1 || true

# Apply IEC958 Non-Audio (AC-3/DTS passthrough)
echo "Setting IEC958 to Non-Audio on card $ALSA_CARD_INDEX, index $IEC958_INDEX..."
# "audio off" sets the Non-Audio bit (for AC-3)
iecset -c "$ALSA_CARD_INDEX" -n "$IEC958_INDEX" audio off rate 48000 >/dev/null 2>&1 || echo "Warning: IEC958 set failed."

# Ensure Unmuted
echo "Unmuting ALSA controls..."
amixer -c "$ALSA_CARD_INDEX" set Master unmute 100% >/dev/null 2>&1 || true
amixer -c "$ALSA_CARD_INDEX" set PCM unmute 100% >/dev/null 2>&1 || true
# Unmute the specific IEC958 control
amixer -c "$ALSA_CARD_INDEX" set "IEC958,$IEC958_INDEX" unmute >/dev/null 2>&1 || true

# Launch Pipeline
echo "Launching pipeline to $DIRECT_ALSA_DEVICE..."
(
    "${APP_BIN}" --stdout \
    --latency "$LOW_LATENCY_NODE_LATENCY" \
    --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
    --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
    2>/dev/null \
    | aplay -D "$DIRECT_ALSA_DEVICE" \
    -t raw -f S16_LE -r 48000 -c 2 --buffer-time="$DIRECT_ALSA_BUFFER_TIME" --period-time="$DIRECT_ALSA_PERIOD_TIME" \
    > /dev/null 2>&1
) &
APP_PID=$!
echo "Pipeline launched with PID $APP_PID"

# Trap cleanup
trap 'cleanup "Cleaning up..."; exit' INT TERM EXIT


# 3. Post-Launch Configuration
# ----------------------------

# Set Default Sink to our virtual input
echo "Setting 'AC-3 Encoder Input' as default sink..."
pactl set-default-sink "pw-ac3-live-input" || echo "Warning: Could not set default sink."
if command -v wpctl >/dev/null 2>&1; then
    # Try to find the ID for "AC-3 Encoder Input" and set default
    ENCODER_ID=$(wpctl status | awk '/AC-3 Encoder Input/ && match($0, /[0-9]+/) {print substr($0, RSTART, RLENGTH); exit}')
    if [ -n "$ENCODER_ID" ]; then
        wpctl set-default "$ENCODER_ID" || true
    fi
fi

# Move existing streams to encoder input
echo "Moving existing app streams to 'AC-3 Encoder Input'..."
encoder_stream_id=$(find_pw_ac3_live_sink_input_id || true)

pactl list sink-inputs short | while read -r stream_id _; do
    [ -z "$stream_id" ] && continue
    if [ -n "$encoder_stream_id" ] && [ "$stream_id" = "$encoder_stream_id" ]; then
        continue
    fi
    if pactl move-sink-input "$stream_id" "pw-ac3-live-input" >/dev/null 2>&1; then
        echo "Moved sink-input #$stream_id to pw-ac3-live-input."
    fi
done

# Normalize volumes
echo "Normalizing pw-ac3-live node/stream volumes..."
if pactl list sinks short | awk '$2=="pw-ac3-live-input" { found=1 } END { exit(found ? 0 : 1) }'; then
    pactl set-sink-volume "pw-ac3-live-input" 100% || true
    pactl set-sink-mute "pw-ac3-live-input" 0 || true
fi

stream_id=$(find_pw_ac3_live_sink_input_id)
if [ -n "$stream_id" ]; then
    pactl set-sink-input-volume "$stream_id" 100% || true
    pactl set-sink-input-mute "$stream_id" 0 || true
    echo "Set pw-ac3-live playback stream volume to 100% (sink-input #$stream_id)."
fi

echo "LAUNCH SUCCESSFUL"
echo "pw-ac3-live is running on direct ALSA ($DIRECT_ALSA_DEVICE)."
echo "Press Ctrl+C to stop."
echo "========================================"

wait $APP_PID
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "Error: Pipeline exited with code $EXIT_CODE"
fi

exit $EXIT_CODE
