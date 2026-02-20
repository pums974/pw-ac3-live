#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_LIB="${ROOT_DIR}/scripts/lib/launch_common.sh"

LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-64/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-16}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-64}"
APP_TARGET_OVERRIDE="${PW_AC3_APP_TARGET:-}"
CONNECT_TARGET_OVERRIDE="${PW_AC3_CONNECT_TARGET:-}"
APP_BIN_OVERRIDE="${PW_AC3_APP_BIN:-}"

APP_PID=""
# shellcheck disable=SC2034 # Mutated indirectly via begin_cleanup_once.
CLEANUP_DONE=0
ORIGINAL_DEFAULT_SINK=""
ORIGINAL_CARD_PROFILE=""
SELECTED_CARD_NAME=""
APP_ISOLATED_SESSION=0
APP_BIN=""
APP_TARGET=""
CONNECT_TARGET=""

if [ ! -r "$COMMON_LIB" ]; then
  echo "Error: shared launcher library not found: $COMMON_LIB"
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_LIB"

sink_exists() {
  local sink_name="$1"
  pactl list sinks short | awk -F'\t' -v sink="$sink_name" '$2 == sink { found = 1 } END { exit(found ? 0 : 1) }'
}

restore_default_sink_and_streams() {
  if [ -z "$ORIGINAL_DEFAULT_SINK" ]; then
    return 0
  fi

  if ! sink_exists "$ORIGINAL_DEFAULT_SINK"; then
    warn "Original default sink '$ORIGINAL_DEFAULT_SINK' is not available; skipping restore."
    return 0
  fi

  echo "Restoring default sink: $ORIGINAL_DEFAULT_SINK"
  pactl set-default-sink "$ORIGINAL_DEFAULT_SINK" > /dev/null 2>&1 || warn "Failed to restore default sink."

  if sink_exists "pw-ac3-live-input"; then
    echo "Moving active streams back to original default sink..."
    pactl list sink-inputs short \
      | awk -F'\t' '$2 == "pw-ac3-live-input" { print $1 }' \
      | xargs -r -P 8 -I{} pactl move-sink-input {} "$ORIGINAL_DEFAULT_SINK" > /dev/null 2>&1 || true
  fi
}

restore_card_profile() {
  if [ -z "$SELECTED_CARD_NAME" ] || [ -z "$ORIGINAL_CARD_PROFILE" ]; then
    return 0
  fi

  if pactl set-card-profile "$SELECTED_CARD_NAME" "$ORIGINAL_CARD_PROFILE" > /dev/null 2>&1; then
    echo "Restored card profile: $SELECTED_CARD_NAME -> $ORIGINAL_CARD_PROFILE"
  else
    warn "Failed to restore card profile '$SELECTED_CARD_NAME' to '$ORIGINAL_CARD_PROFILE'."
  fi
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

cleanup() {
  local message="${1:-Cleaning up...}"

  if ! begin_cleanup_once CLEANUP_DONE; then
    return 0
  fi

  echo "$message"
  restore_default_sink_and_streams
  restore_card_profile
  terminate_pipeline
  echo "Cleanup finished"
}

detect_hdmi_card() {
  pactl list cards short | awk '/pci/ { print $2; exit }'
}

detect_hdmi_profile() {
  local card_name="$1"
  pactl list cards | awk -v card="$card_name" '
        $1 == "Name:" { in_card = ($2 == card) }
        in_card && $1 ~ /^output:hdmi-stereo/ {
            gsub(/:$/, "", $1)
            print $1
            exit
        }
        in_card && /^Active Profile:/ { exit }
    '
}

set_hdmi_profile() {
  local card_name="$1"
  local profile_name="$2"

  if pactl set-card-profile "$card_name" "$profile_name"; then
    return 0
  fi

  local fallback_profile="${profile_name}+input:analog-stereo"
  warn "Failed to set profile '$profile_name'; retrying '$fallback_profile'."
  pactl set-card-profile "$card_name" "$fallback_profile" || warn "Could not set HDMI profile for '$card_name'."
}

detect_hdmi_sink() {
  local device_id="$1"
  pactl list sinks short | awk -F'\t' -v device="$device_id" '
        index($2, device) && index($2, "hdmi-stereo") {
            print $1 "\t" $2
            exit
        }
    '
}

configure_hdmi_passthrough() {
  local sink_index="$1"

  echo "Configuring sink formats and volume..."
  if ! pactl set-sink-formats "$sink_index" 'ac3-iec61937, format.rate = "[ 48000 ]"'; then
    warn "Exact AC3 format string failed, retrying generic ac3-iec61937."
    pactl set-sink-formats "$sink_index" "ac3-iec61937" || warn "Failed to set AC3 sink formats."
  fi

  set_sink_full_volume_unmuted "$sink_index"
}

link_encoder_output_to_target() {
  local target_pattern="$1"
  local -a output_ports=()
  local -a target_ports=()

  mapfile -t output_ports < <(pw-link -o | awk '/^pw-ac3-live-output:/ { print $1 }' | sort)
  if [ "${#output_ports[@]}" -eq 0 ]; then
    echo "Error: pw-ac3-live-output node not found or has no output ports."
    echo "Is the daemon running?"
    return 1
  fi

  mapfile -t target_ports < <(pw-link -i | awk -v node="$target_pattern" '
        {
            split($1, parts, ":")
            if (parts[1] == node) {
                print $1
            }
        }
    ' | sort)

  if [ "${#target_ports[@]}" -eq 0 ]; then
    echo "Error: No input ports found for node '$target_pattern'."
    echo "Available input nodes:"
    pw-link -i | awk -F: '{print $1}' | sort -u
    echo "Tip: set PW_AC3_CONNECT_ALLOW_FALLBACK=1 to enable substring matching."
    return 1
  fi

  local num_output num_target limit
  num_output="${#output_ports[@]}"
  num_target="${#target_ports[@]}"
  limit="$num_output"
  if [ "$num_target" -lt "$num_output" ]; then
    limit="$num_target"
  fi

  echo "Linking $num_output output ports to $num_target target ports..."

  local success_count=0
  local failed_count=0
  local permission_denied_count=0

  for ((i = 0; i < limit; i++)); do
    local src dst link_output link_rc
    src="${output_ports[$i]}"
    dst="${target_ports[$i]}"
    echo "Connecting $src -> $dst"
    link_rc=0
    link_output="$(pw-link "$src" "$dst" 2>&1)" || link_rc=$?

    if [ "$link_rc" -eq 0 ]; then
      success_count=$((success_count + 1))
      continue
    fi

    if echo "$link_output" | grep -Eiq "(file exists|already linked|existe)"; then
      echo "Link already exists for $src -> $dst."
      success_count=$((success_count + 1))
      continue
    fi

    echo "$link_output"
    echo "Failed to link $src -> $dst."
    failed_count=$((failed_count + 1))
    if echo "$link_output" | grep -Eiq "operation not permitted|permission denied|not permitted"; then
      permission_denied_count=$((permission_denied_count + 1))
    fi
  done

  if [ "$success_count" -eq 0 ] && [ "$failed_count" -gt 0 ] && [ "$permission_denied_count" -gt 0 ]; then
    echo "Error: All link attempts were denied by policy/permissions."
    return 13
  fi

  return 0
}

main() {
  preflight_checks
  stop_stale_runtime
  prepare_pipewire_output
  launch_pipeline
  configure_post_launch_routing
  monitor_pipeline
}

preflight_checks() {
  require_command pactl
  require_command pw-link
  resolve_pw_ac3_live_bin_or_die "$ROOT_DIR" "$APP_BIN_OVERRIDE" APP_BIN
}

stop_stale_runtime() {
  echo "Stopping any existing instances..."
  stop_existing_pw_ac3_live 1
}

prepare_pipewire_output() {
  echo "Detecting HDMI card..."
  local card_name
  card_name="$(detect_hdmi_card)"
  if [ -z "$card_name" ]; then
    echo "Error: Could not automatically detect a PCI sound card."
    echo "Cards found:"
    pactl list cards short
    exit 1
  fi
  echo "Selected card: $card_name"
  SELECTED_CARD_NAME="$card_name"

  local device_id
  device_id="${card_name#alsa_card.}"

  ORIGINAL_DEFAULT_SINK="$(pactl get-default-sink 2> /dev/null || true)"
  if [ -n "$ORIGINAL_DEFAULT_SINK" ]; then
    echo "Original default sink: $ORIGINAL_DEFAULT_SINK"
  else
    warn "Could not capture original default sink."
  fi
  ORIGINAL_CARD_PROFILE="$(get_card_active_profile "$card_name")"
  if [ -n "$ORIGINAL_CARD_PROFILE" ]; then
    echo "Original card profile: $ORIGINAL_CARD_PROFILE"
  fi

  local profile_name
  profile_name="$(detect_hdmi_profile "$card_name")"
  if [ -z "$profile_name" ]; then
    warn "Could not find an explicit 'output:hdmi-stereo' profile; using fallback."
    profile_name="output:hdmi-stereo"
  fi
  echo "Using profile: $profile_name"
  set_hdmi_profile "$card_name" "$profile_name"

  echo "Finding HDMI sink..."
  local sink_info sink_index sink_name
  sink_info="$(detect_hdmi_sink "$device_id")"
  IFS=$'\t' read -r sink_index sink_name <<<"$sink_info"
  if [ -z "${sink_name:-}" ]; then
    echo "Error: Could not find HDMI stereo sink matching '$device_id'."
    pactl list sinks short
    exit 1
  fi
  echo "Selected sink: $sink_name (index: $sink_index)"

  configure_hdmi_passthrough "$sink_index"

  local app_target connect_target
  app_target="${APP_TARGET_OVERRIDE:-$sink_name}"
  connect_target="${CONNECT_TARGET_OVERRIDE:-$sink_name}"
  APP_TARGET="$app_target"
  CONNECT_TARGET="$connect_target"
  echo "App binary: $APP_BIN"
  echo "App target: $APP_TARGET"
  echo "Link target: $CONNECT_TARGET"
}

launch_pipeline() {
  local -a app_args=(
    --target "$APP_TARGET"
    --latency "$LOW_LATENCY_NODE_LATENCY"
    --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE"
    --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES"
  )

  echo "Launching pw-ac3-live..."
  if command -v setsid > /dev/null 2>&1; then
    setsid env RUST_LOG=info "$APP_BIN" "${app_args[@]}" 2>/dev/null &
    APP_PID=$!
    APP_ISOLATED_SESSION=1
  else
    RUST_LOG=info "$APP_BIN" "${app_args[@]}" 2>/dev/null &
    APP_PID=$!
    APP_ISOLATED_SESSION=0
  fi
  echo "App launched with PID $APP_PID"
}

configure_post_launch_routing() {
  echo "Waiting for pw-ac3-live-input node..."
  if ! wait_for_node_input_ports "pw-ac3-live-input" 20 0.5; then
    warn "pw-ac3-live-input input ports not found yet. App might still be starting."
  fi

  echo "Setting default sink to AC-3 Encoder Input..."
  if ! configure_encoder_input_routing "pw-ac3-live-input" 20 0.25 20 0.5; then
    warn "Could not set default sink via pactl."
  fi

  echo "Ensuring encoder output is linked to target sink..."
  link_encoder_output_to_target "$CONNECT_TARGET"
}

monitor_pipeline() {
  echo "========================================"
  echo "LAUNCH SUCCESSFUL"
  echo "pw-ac3-live is running. Keep receiver volume controlled (bitstream path)."
  echo "Press Ctrl+C to stop."
  echo "========================================"

  local app_exit=0
  if ! wait "$APP_PID"; then
    app_exit=$?
  fi
  APP_PID=""
  return "$app_exit"
}

trap 'cleanup "Interrupted"; exit 130' INT TERM
trap 'cleanup "Cleaning up..."' EXIT

main
