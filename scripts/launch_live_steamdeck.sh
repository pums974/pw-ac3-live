#!/usr/bin/env bash
set -euo pipefail

# Goal: setup HDMI for AC-3 passthrough and launch the encoder on Steam Deck.
# This script is hardcoded for known Steam Deck + Dock hardware.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_LIB="${ROOT_DIR}/scripts/lib/launch_common.sh"

APP_BIN_OVERRIDE="${PW_AC3_APP_BIN:-}"

LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-1536/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-4}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-1536}"

DIRECT_ALSA_DEVICE="hw:0,8"
HDMI_CARD_NAME="alsa_card.pci-0000_04_00.1"
INTERNAL_SPEAKER_CARD_NAME="alsa_card.pci-0000_04_00.5-platform-nau8821-max"
LOOPBACK_SINK_NAME="alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2"

ALSA_CARD_INDEX=0
IEC958_INDEX=2

DIRECT_ALSA_BUFFER_TIME="${PW_AC3_DIRECT_ALSA_BUFFER_TIME:-60000}"
DIRECT_ALSA_PERIOD_TIME="${PW_AC3_DIRECT_ALSA_PERIOD_TIME:-15000}"

APP_BIN=""
APP_PID=""
POST_LAUNCH_CONFIG_PID=""
INTERNAL_SPEAKER_PROFILE=""
APP_ISOLATED_SESSION=0
# shellcheck disable=SC2034 # Mutated indirectly via begin_cleanup_once.
CLEANUP_DONE=0

if [ ! -r "$COMMON_LIB" ]; then
  echo "Error: shared launcher library not found: $COMMON_LIB"
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_LIB"

disable_internal_speaker_profile() {
  local active_profile=""

  if [ -n "$INTERNAL_SPEAKER_PROFILE" ]; then
    return 0
  fi

  active_profile="$(get_card_active_profile "$INTERNAL_SPEAKER_CARD_NAME")"
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

terminate_post_launch_config_task() {
  if [ -z "$POST_LAUNCH_CONFIG_PID" ]; then
    return 0
  fi

  terminate_pid_with_retries "$POST_LAUNCH_CONFIG_PID" 3 0.03 0 || true
  pkill -P "$POST_LAUNCH_CONFIG_PID" > /dev/null 2>&1 || true
  POST_LAUNCH_CONFIG_PID=""
}

terminate_pipeline() {
  if [ -z "$APP_PID" ]; then
    return 0
  fi

  echo "Stopping pw-ac3-live pipeline..."
  local use_process_group=0
  if [ "$APP_ISOLATED_SESSION" = "1" ]; then
    use_process_group=1
  fi
  if ! terminate_pid_with_retries "$APP_PID" 6 0.05 "$use_process_group"; then
    warn "Graceful shutdown timed out; forcing process stop."
  fi
  APP_PID=""
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
  echo "Waiting for pw-ac3-live-input node..."
  if ! wait_for_node_input_ports "pw-ac3-live-input" 20 0.1; then
    warn "pw-ac3-live-input input ports not found yet. App might still be starting."
  fi

  echo "Configuring AC-3 Encoder Input routing..."
  if ! configure_encoder_input_routing "pw-ac3-live-input" 8 0.05 12 0.1; then
    warn "Could not set default sink to pw-ac3-live-input."
  fi
}

preflight_checks() {
  require_command aplay
  require_command pactl
  require_command amixer
  require_command pw-link
  resolve_pw_ac3_live_bin_or_die "$ROOT_DIR" "$APP_BIN_OVERRIDE" APP_BIN

  if ! command -v iecset > /dev/null 2>&1; then
    warn "'iecset' not found. IEC958 status may not be forced."
  fi
}

stop_stale_runtime() {
  echo "Stopping any existing instances..."
  stop_existing_pw_ac3_live 1

  pactl list short modules | awk '/sink_name=pw_ac3_direct_hdmi/ { print $1 }' | xargs -r -I{} pactl unload-module {} > /dev/null 2>&1 || true
}

prepare_direct_alsa_output() {
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
}

launch_pipeline() {
  local -a app_args=(
    --stdout
    --latency "$LOW_LATENCY_NODE_LATENCY"
    --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE"
    --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES"
  )

  echo "App binary: $APP_BIN"
  echo "Direct ALSA device: $DIRECT_ALSA_DEVICE"
  echo "Launching pw-ac3-live..."
  (
    "${APP_BIN}" "${app_args[@]}" 2> /dev/null \
      | aplay -D "$DIRECT_ALSA_DEVICE" \
        -t raw -f S16_LE -r 48000 -c 2 --buffer-time="$DIRECT_ALSA_BUFFER_TIME" --period-time="$DIRECT_ALSA_PERIOD_TIME" \
        > /dev/null 2>&1
  ) &
  APP_PID=$!
  APP_ISOLATED_SESSION=0
  echo "App launched with PID $APP_PID"
}

start_post_launch_routing_task() {
  configure_post_launch_routing &
  POST_LAUNCH_CONFIG_PID=$!
}

monitor_pipeline() {
  echo "========================================"
  echo "LAUNCH SUCCESSFUL"
  echo "pw-ac3-live is running on direct ALSA ($DIRECT_ALSA_DEVICE)."
  echo "Press Ctrl+C to stop."
  echo "========================================"

  local app_exit=0
  if ! wait "$APP_PID"; then
    app_exit=$?
  fi
  APP_PID=""
  return "$app_exit"
}

cleanup() {
  local message="${1:-Cleaning up...}"

  if ! begin_cleanup_once CLEANUP_DONE; then
    return 0
  fi

  echo "$message"
  terminate_post_launch_config_task
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

main() {
  preflight_checks
  stop_stale_runtime
  prepare_direct_alsa_output
  launch_pipeline
  start_post_launch_routing_task
  monitor_pipeline
}

trap 'cleanup "Interrupted"; exit 130' INT TERM
trap 'cleanup "Cleaning up..."' EXIT

main
