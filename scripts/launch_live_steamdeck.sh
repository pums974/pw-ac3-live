#!/bin/bash
set -e

# Goal: setup HDMI for AC-3 passthrough and launch the encoder on Steam Deck.
# This script is hardcoded for known Steam Deck + Dock hardware.

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Application binary
APP_BIN="${ROOT_DIR}/bin/pw-ac3-live"

# Latency tuning
LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-1536/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-4}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-1536}"

# Steam Deck hardware identifiers
DIRECT_ALSA_DEVICE="hw:0,8"
HDMI_CARD_NAME="alsa_card.pci-0000_04_00.1"
INTERNAL_SPEAKER_CARD_NAME="alsa_card.pci-0000_04_00.5-platform-nau8821-max"
LOOPBACK_SINK_NAME="alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2"

# ALSA IEC958 controls
ALSA_CARD_INDEX=0
IEC958_INDEX=2

# Direct ALSA output parameters
DIRECT_ALSA_BUFFER_TIME="${PW_AC3_DIRECT_ALSA_BUFFER_TIME:-60000}"
DIRECT_ALSA_PERIOD_TIME="${PW_AC3_DIRECT_ALSA_PERIOD_TIME:-15000}"

# Runtime state
CLEANUP_DONE=0
APP_PID=""
POST_LAUNCH_CONFIG_PID=""
INTERNAL_SPEAKER_PROFILE=""

# ------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------

warn() {
  echo "Warning: $1"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Error: '$cmd' not found. Cannot proceed."
    exit 1
  fi
}

get_card_active_profile() {
  local card_name="$1"
  pactl list cards | awk -v card="$card_name" '
        $1 == "Name:" {
            in_card = ($2 == card)
        }
        in_card && $1 == "Active" && $2 == "Profile:" {
            $1 = ""
            $2 = ""
            sub(/^[[:space:]]+/, "", $0)
            print $0
            exit
        }
    '
}

# Disable the internal speakers by setting their card profile to "off".
# We capture the original profile once and restore it during cleanup.
disable_internal_speaker_profile() {
  local active_profile=""

  if [ -n "$INTERNAL_SPEAKER_PROFILE" ]; then
    return 0
  fi

  active_profile=$(get_card_active_profile "$INTERNAL_SPEAKER_CARD_NAME")
  if [ -z "$active_profile" ]; then
    warn "Internal speaker card not found: $INTERNAL_SPEAKER_CARD_NAME"
    return 0
  fi

  INTERNAL_SPEAKER_PROFILE="$active_profile"
  if [ "$active_profile" = "off" ]; then
    echo "Internal speaker card already off: $INTERNAL_SPEAKER_CARD_NAME"
    return 0
  fi

  if pactl set-card-profile "$INTERNAL_SPEAKER_CARD_NAME" off > /dev/null 2>&1; then
    echo "Disabled internal speaker profile: $INTERNAL_SPEAKER_CARD_NAME ($active_profile -> off)"
  else
    warn "Failed to disable internal speaker card profile '$INTERNAL_SPEAKER_CARD_NAME'."
  fi
}

restore_internal_speaker_profile() {
  if [ -z "$INTERNAL_SPEAKER_PROFILE" ]; then
    return 0
  fi

  if pactl set-card-profile "$INTERNAL_SPEAKER_CARD_NAME" "$INTERNAL_SPEAKER_PROFILE" > /dev/null 2>&1; then
    echo "Restored internal speaker profile: $INTERNAL_SPEAKER_CARD_NAME -> $INTERNAL_SPEAKER_PROFILE"
  else
    warn "Failed to restore internal speaker profile '$INTERNAL_SPEAKER_CARD_NAME' to '$INTERNAL_SPEAKER_PROFILE'."
  fi
}

terminate_pipeline() {
  if [ -z "$APP_PID" ]; then
    return 0
  fi

  echo "Killing app..."
  kill "$APP_PID" > /dev/null 2>&1 || return 0

  local retries=3
  for _ in $(seq 1 "$retries"); do
    if ! kill -0 "$APP_PID" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.03
  done

  kill -9 "$APP_PID" > /dev/null 2>&1 || true
}

restore_hdmi_audio_state() {
  local restore_profile="output:hdmi-stereo-extra2"

  if pactl set-card-profile "$HDMI_CARD_NAME" "$restore_profile" > /dev/null 2>&1; then
    echo "Restored HDMI card profile: $restore_profile"
  else
    warn "Failed to restore HDMI card profile '$restore_profile' on '$HDMI_CARD_NAME'."
  fi

  if pactl set-default-sink "$LOOPBACK_SINK_NAME" > /dev/null 2>&1; then
    echo "Restored default sink: $LOOPBACK_SINK_NAME"
  else
    warn "Failed to restore default sink '$LOOPBACK_SINK_NAME'."
  fi
}

configure_post_launch_routing() {
  echo "Configuring default sink..."
  local set_default_ok=0
  for _ in $(seq 1 8); do
    if pactl set-default-sink "pw-ac3-live-input" > /dev/null 2>&1; then
      set_default_ok=1
      break
    fi
    sleep 0.05
  done
  if [ "$set_default_ok" = "0" ]; then
    warn "Could not set default sink to pw-ac3-live-input."
  fi

  echo "Moving existing streams..."
  pactl list sink-inputs short | cut -f1 | xargs -r -P 8 -I{} pactl move-sink-input {} "pw-ac3-live-input" > /dev/null 2>&1 || true

  echo "Normalizing pw-ac3-live node/stream volumes..."
  pactl set-sink-volume "pw-ac3-live-input" 100% || true
  pactl set-sink-mute "pw-ac3-live-input" 0 || true
}

cleanup() {
  local message="${1:-Cleaning up...}"

  if [ "$CLEANUP_DONE" = "1" ]; then
    return 0
  fi
  CLEANUP_DONE=1

  echo "Starting cleanup: $message"
  disable_internal_speaker_profile

  if [ -n "$POST_LAUNCH_CONFIG_PID" ]; then
    kill "$POST_LAUNCH_CONFIG_PID" > /dev/null 2>&1 || true
    pkill -P "$POST_LAUNCH_CONFIG_PID" > /dev/null 2>&1 || true
  fi

  terminate_pipeline

  local iec_restore_pid=""
  if command -v iecset > /dev/null 2>&1; then
    (iecset -c "$ALSA_CARD_INDEX" -n "$IEC958_INDEX" audio on > /dev/null 2>&1 || true) &
    iec_restore_pid=$!
  fi

  restore_hdmi_audio_state
  restore_internal_speaker_profile

  if [ -n "$iec_restore_pid" ]; then
    wait "$iec_restore_pid" 2> /dev/null || true
  fi

  echo "Cleanup finished"
}

# ------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------

main() {
  pactl list short modules | awk '/sink_name=pw_ac3_direct_hdmi/ { print $1 }' | xargs -r -I{} pactl unload-module {} > /dev/null 2>&1 || true

  require_command aplay
  require_command pactl
  require_command amixer
  if ! command -v iecset > /dev/null 2>&1; then
    warn "'iecset' not found. IEC958 status may not be forced."
  fi

  disable_internal_speaker_profile

  echo "Disabling HDMI card profile '$HDMI_CARD_NAME' to release ALSA device..."
  pactl set-card-profile "$HDMI_CARD_NAME" off > /dev/null 2>&1 || true

  if command -v iecset > /dev/null 2>&1; then
    echo "Setting IEC958 to Non-Audio on card $ALSA_CARD_INDEX, index $IEC958_INDEX..."
    iecset -c "$ALSA_CARD_INDEX" -n "$IEC958_INDEX" audio off rate 48000 > /dev/null 2>&1 || warn "IEC958 set failed."
  fi

  echo "Unmuting ALSA controls..."
  amixer -c "$ALSA_CARD_INDEX" set Master unmute 100% > /dev/null 2>&1 &
  local amixer_master_pid=$!
  amixer -c "$ALSA_CARD_INDEX" set PCM unmute 100% > /dev/null 2>&1 &
  local amixer_pcm_pid=$!
  amixer -c "$ALSA_CARD_INDEX" set "IEC958,$IEC958_INDEX" unmute > /dev/null 2>&1 &
  local amixer_iec_pid=$!
  wait "$amixer_master_pid" 2> /dev/null || true
  wait "$amixer_pcm_pid" 2> /dev/null || true
  wait "$amixer_iec_pid" 2> /dev/null || true

  echo "Launching pipeline to $DIRECT_ALSA_DEVICE..."
  (
    "${APP_BIN}" --stdout \
      --latency "$LOW_LATENCY_NODE_LATENCY" \
      --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE" \
      --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES" \
      2> /dev/null \
      | aplay -D "$DIRECT_ALSA_DEVICE" \
        -t raw -f S16_LE -r 48000 -c 2 --buffer-time="$DIRECT_ALSA_BUFFER_TIME" --period-time="$DIRECT_ALSA_PERIOD_TIME" \
        > /dev/null 2>&1
  ) &
  APP_PID=$!
  echo "Pipeline launched with PID $APP_PID"

  configure_post_launch_routing &
  POST_LAUNCH_CONFIG_PID=$!

  echo "Launch successful - monitoring..."
  echo "pw-ac3-live is running on direct ALSA ($DIRECT_ALSA_DEVICE)."
  echo "Press Ctrl+C to stop."
  echo "========================================"
  restore_internal_speaker_profile

  local exit_code=0
  if ! wait "$APP_PID"; then
    exit_code=$?
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "Error: Pipeline exited with code $exit_code"
  fi

  return "$exit_code"
}

echo "Initial cleanup..."
pkill -INT -f "pw-ac3-live" || true

trap 'cleanup "Interrupted"; exit 130' INT TERM
trap 'cleanup "Cleaning up..."' EXIT

main
exit $?
