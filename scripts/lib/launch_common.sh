#!/usr/bin/env bash

warn() {
  echo "Warning: $1"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Error: '$cmd' not found."
    exit 1
  fi
}

resolve_pw_ac3_live_bin() {
  local root_dir="$1"
  local override_path="${2:-}"

  if [ -n "$override_path" ] && [ -x "$override_path" ]; then
    printf '%s\n' "$override_path"
    return 0
  fi

  if [ -x "${root_dir}/bin/pw-ac3-live" ]; then
    printf '%s\n' "${root_dir}/bin/pw-ac3-live"
    return 0
  fi

  if [ -x "${root_dir}/target/release/pw-ac3-live" ]; then
    printf '%s\n' "${root_dir}/target/release/pw-ac3-live"
    return 0
  fi

  return 1
}

resolve_pw_ac3_live_bin_or_die() {
  local root_dir="$1"
  local override_path="${2:-}"
  local output_var="$3"
  local resolved_path=""

  resolved_path="$(resolve_pw_ac3_live_bin "$root_dir" "$override_path" || true)"
  if [ -z "$resolved_path" ]; then
    print_pw_ac3_live_bin_resolution_error "$root_dir" "$override_path"
    exit 1
  fi

  printf -v "$output_var" '%s' "$resolved_path"
}

print_pw_ac3_live_bin_resolution_error() {
  local root_dir="$1"
  local override_path="${2:-}"

  echo "Error: pw-ac3-live binary not found."
  echo "Tried:"
  if [ -n "$override_path" ]; then
    echo "  PW_AC3_APP_BIN=$override_path"
  fi
  echo "  ${root_dir}/bin/pw-ac3-live"
  echo "  ${root_dir}/target/release/pw-ac3-live"
  echo "Build it first with: cargo build --release"
}

terminate_pid_with_retries() {
  local pid="${1:-}"
  local retries="${2:-6}"
  local sleep_seconds="${3:-0.05}"
  local process_group="${4:-0}"

  if [ -z "$pid" ]; then
    return 0
  fi

  local target="$pid"
  if [ "$process_group" = "1" ]; then
    target="-$pid"
  fi

  if ! kill -0 -- "$target" > /dev/null 2>&1; then
    return 0
  fi

  kill -TERM -- "$target" > /dev/null 2>&1 || true

  for _ in $(seq 1 "$retries"); do
    if ! kill -0 -- "$target" > /dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  kill -KILL -- "$target" > /dev/null 2>&1 || true
  return 2
}

stop_existing_pw_ac3_live() {
  local settle_sleep="${1:-0}"
  pkill -INT -f "pw-ac3-live" > /dev/null 2>&1 || true
  if [ "$settle_sleep" != "0" ]; then
    sleep "$settle_sleep"
  fi
}

begin_cleanup_once() {
  local guard_var="$1"
  local guard_value="${!guard_var:-0}"

  if [ "$guard_value" = "1" ]; then
    return 1
  fi

  printf -v "$guard_var" '1'
  return 0
}

get_card_active_profile() {
  local card_name="$1"
  pactl list cards | awk -v card="$card_name" '
        $1 == "Name:" { in_card = ($2 == card) }
        in_card && $1 == "Active" && $2 == "Profile:" {
            $1 = ""
            $2 = ""
            sub(/^[[:space:]]+/, "", $0)
            print $0
            exit
        }
    '
}

set_default_sink_with_retries() {
  local sink_name="$1"
  local retries="$2"
  local sleep_seconds="$3"

  for _ in $(seq 1 "$retries"); do
    if pactl set-default-sink "$sink_name" > /dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

wait_for_node_input_ports() {
  local node_name="$1"
  local retries="$2"
  local sleep_seconds="$3"

  for _ in $(seq 1 "$retries"); do
    if pw-link -i | grep -Fq "$node_name"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

find_pw_ac3_live_sink_input_id() {
  pactl list sink-inputs | awk '
        /^Sink Input #/ { id = substr($3, 2); next }
        /^[[:space:]]*application.name = "pw-ac3-live"/ { print id; exit }
        /^[[:space:]]*Application Name: pw-ac3-live$/ { print id; exit }
    '
}

normalize_pw_ac3_live_levels() {
  local sink_name="${1:-pw-ac3-live-input}"
  local retries="${2:-20}"
  local sleep_seconds="${3:-0.5}"
  local stream_id=""

  set_sink_full_volume_unmuted "$sink_name"

  for _ in $(seq 1 "$retries"); do
    stream_id="$(find_pw_ac3_live_sink_input_id)"
    if [ -n "$stream_id" ]; then
      pactl set-sink-input-volume "$stream_id" 100% || true
      pactl set-sink-input-mute "$stream_id" 0 || true
      echo "Set pw-ac3-live playback stream volume to 100% (sink-input #$stream_id)."
      return 0
    fi
    sleep "$sleep_seconds"
  done

  warn "Could not find pw-ac3-live playback sink-input; leaving stream volume unchanged."
  return 1
}

set_default_encoder_sink_and_move_streams() {
  local retries="$1"
  local sleep_seconds="$2"
  local sink_name="${3:-pw-ac3-live-input}"
  local default_sink_status=0

  if ! set_default_sink_with_retries "$sink_name" "$retries" "$sleep_seconds"; then
    default_sink_status=1
  fi

  move_all_sink_inputs_to "$sink_name"
  return "$default_sink_status"
}

configure_encoder_input_routing() {
  local sink_name="${1:-pw-ac3-live-input}"
  local retries="${2:-20}"
  local sleep_seconds="${3:-0.25}"
  local stream_retries="${4:-20}"
  local stream_sleep_seconds="${5:-0.5}"
  local default_sink_status=0

  if ! set_default_encoder_sink_and_move_streams "$retries" "$sleep_seconds" "$sink_name"; then
    default_sink_status=1
  fi

  normalize_pw_ac3_live_levels "$sink_name" "$stream_retries" "$stream_sleep_seconds" || true
  return "$default_sink_status"
}

move_all_sink_inputs_to() {
  local sink_name="$1"
  pactl list sink-inputs short | cut -f1 | xargs -r -P 8 -I{} pactl move-sink-input {} "$sink_name" > /dev/null 2>&1 || true
}

set_sink_full_volume_unmuted() {
  local sink_name="$1"
  pactl set-sink-volume "$sink_name" 100% || true
  pactl set-sink-mute "$sink_name" 0 || true
}
