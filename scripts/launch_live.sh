#!/bin/bash
set -e

# Goal: Setup HDMI for AC3 passthrough and launch the encoder

# FIX: Set PulseAudio latency to avoid stuttering on Steam Deck
export PULSE_LATENCY_MSEC=60

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOW_LATENCY_BUFFER_SIZE="${PW_AC3_BUFFER_SIZE:-6144}"
LOW_LATENCY_OUTPUT_BUFFER_SIZE="${PW_AC3_OUTPUT_BUFFER_SIZE:-3072}"
LOW_LATENCY_NODE_LATENCY="${PW_AC3_NODE_LATENCY:-1536/48000}"
LOW_LATENCY_THREAD_QUEUE="${PW_AC3_FFMPEG_THREAD_QUEUE_SIZE:-4}"
LOW_LATENCY_CHUNK_FRAMES="${PW_AC3_FFMPEG_CHUNK_FRAMES:-1536}"
ENABLE_LATENCY_PROFILE="${PW_AC3_PROFILE_LATENCY:-1}"
TARGET_SINK_OVERRIDE="${PW_AC3_TARGET_SINK:-}"
APP_TARGET_OVERRIDE="${PW_AC3_APP_TARGET:-}"
CONNECT_TARGET_OVERRIDE="${PW_AC3_CONNECT_TARGET:-}"
PLAYBACK_MODE="${PW_AC3_PLAYBACK_MODE:-native}"
DIRECT_ALSA_DEVICE_OVERRIDE="${PW_AC3_DIRECT_ALSA_DEVICE:-}"
DIRECT_ALSA_DISABLE_PROFILE="${PW_AC3_DIRECT_ALSA_DISABLE_PROFILE:-0}"
SHOW_RUNTIME_LOGS="${PW_AC3_SHOW_RUNTIME_LOGS:-0}"
DIRECT_ALSA_FALLBACK="${PW_AC3_DIRECT_ALSA_FALLBACK:-1}"
DIRECT_ALSA_AUTO_IEC958="${PW_AC3_DIRECT_ALSA_AUTO_IEC958:-1}"
DIRECT_ALSA_FORCE_PROFILE_DEVICE="${PW_AC3_DIRECT_ALSA_FORCE_PROFILE_DEVICE:-1}"
DIRECT_ALSA_SKIP_IECSET="${PW_AC3_DIRECT_ALSA_SKIP_IECSET:-0}"
DIRECT_ALSA_RESTORE_PROFILE_AFTER_OPEN="${PW_AC3_DIRECT_ALSA_RESTORE_PROFILE_AFTER_OPEN:-0}"
DIRECT_ALSA_IEC958_SCAN_ALL="${PW_AC3_DIRECT_ALSA_IEC958_SCAN_ALL:-1}"
DIRECT_ALSA_USE_HDMI_PLUGIN="${PW_AC3_DIRECT_ALSA_USE_HDMI_PLUGIN:-0}"
DIRECT_ALSA_HDMI_AES_PARAMS="${PW_AC3_DIRECT_ALSA_HDMI_AES_PARAMS:-AES0=0x6}"
DIRECT_ALSA_BUFFER_TIME="${PW_AC3_DIRECT_ALSA_BUFFER_TIME:-60000}"
DIRECT_ALSA_PERIOD_TIME="${PW_AC3_DIRECT_ALSA_PERIOD_TIME:-15000}"
APP_BIN="${ROOT_DIR}/bin/pw-ac3-live"
DEV_BIN="${ROOT_DIR}/target/release/pw-ac3-live"
USE_PACKAGED_BINARY=0
AUTO_APP_TARGET_FROM_CONNECT=1
PW_CLOCK_FORCE_APPLIED=0
CLEANUP_DONE=0
ORIGINAL_DEFAULT_SINK=""
ORIGINAL_CARD_PROFILE=""
RESTORE_PROFILE=""

effective_buffer_size="$LOW_LATENCY_BUFFER_SIZE"
effective_output_buffer_size="${LOW_LATENCY_OUTPUT_BUFFER_SIZE:-$LOW_LATENCY_BUFFER_SIZE}"
latency_frames="${LOW_LATENCY_NODE_LATENCY%%/*}"
if [[ "$latency_frames" =~ ^[0-9]+$ ]] && [ "$latency_frames" -gt 0 ]; then
    min_input_buffer=$((latency_frames * 4))
    min_output_buffer=$((latency_frames * 4))

    if [ "$effective_buffer_size" -lt "$min_input_buffer" ]; then
        echo "Adjusting buffer size from $effective_buffer_size to $min_input_buffer (>= 2x node latency frames)."
        effective_buffer_size="$min_input_buffer"
    fi
    if [ "$effective_output_buffer_size" -lt "$min_output_buffer" ]; then
        echo "Adjusting output buffer size from $effective_output_buffer_size to $min_output_buffer (>= 2x node latency frames)."
        effective_output_buffer_size="$min_output_buffer"
    fi
fi

# Keep encoder feeder cadence aligned with AC-3 frame size when not explicitly overridden.
if [ -z "${PW_AC3_FFMPEG_CHUNK_FRAMES+x}" ] && [[ "$latency_frames" =~ ^[0-9]+$ ]] && [ "$latency_frames" -ge 1536 ]; then
    LOW_LATENCY_CHUNK_FRAMES="$latency_frames"
fi

find_pw_ac3_live_sink_input_id() {
    pactl list sink-inputs | awk '
        /^Sink Input #/ { id = substr($3, 2); next }
        /^[[:space:]]*application.name = "pw-ac3-live"/ { print id; exit }
        /^[[:space:]]*Application Name: pw-ac3-live$/ { print id; exit }
    '
}

sink_name_exists() {
    local sink_name="$1"
    [ -n "$sink_name" ] || return 1
    pactl list sinks short | awk -v target="$sink_name" '$2==target { found=1; exit } END { exit(found ? 0 : 1) }'
}

has_visible_physical_hdmi_sink() {
    pactl list sinks short | awk '
        $2 ~ /^alsa_output\./ && $2 ~ /hdmi/ { found=1; exit }
        END { exit(found ? 0 : 1) }
    '
}

find_internal_recovery_sink() {
    pactl list sinks short | awk '
        $2 ~ /Speaker__sink/ { print $2; exit }
        $2 ~ /Headphones__sink/ { print $2; exit }
        $2 ~ /nau8821/ { print $2; exit }
    '
}

restore_runtime_audio_state() {
    local restore_sink="$ORIGINAL_DEFAULT_SINK"
    local internal_fallback=""

    if [ "$PW_CLOCK_FORCE_APPLIED" = "1" ]; then
        pw-metadata -n settings -d 0 clock.force-quantum >/dev/null 2>&1 || true
        pw-metadata -n settings -d 0 clock.force-rate >/dev/null 2>&1 || true
        PW_CLOCK_FORCE_APPLIED=0
    fi

    if [ -n "$CARD_NAME" ] && [ -n "$RESTORE_PROFILE" ]; then
        if pactl set-card-profile "$CARD_NAME" "$RESTORE_PROFILE" >/dev/null 2>&1; then
            echo "Restored card profile: $RESTORE_PROFILE"
        else
            echo "Warning: Failed to restore card profile '$RESTORE_PROFILE' on '$CARD_NAME'."
        fi
    fi

    # If direct ALSA was used and original default is loopback HDMI-only, prefer internal sink fallback.
    if [ "${USE_DIRECT_APLAY:-0}" = "1" ] && [ -n "$restore_sink" ] && [[ "$restore_sink" == alsa_loopback_device.*hdmi* ]]; then
        if ! has_visible_physical_hdmi_sink; then
            internal_fallback="$(find_internal_recovery_sink || true)"
            if [ -n "$internal_fallback" ]; then
                echo "Info: Recovery fallback to internal sink '$internal_fallback' (physical HDMI sink not visible)."
                restore_sink="$internal_fallback"
            fi
        fi
    fi

    if [ -n "$restore_sink" ]; then
        if ! sink_name_exists "$restore_sink"; then
            internal_fallback="$(find_internal_recovery_sink || true)"
            if [ -n "$internal_fallback" ]; then
                echo "Warning: Restore target sink '$restore_sink' is unavailable; using internal sink '$internal_fallback'."
                restore_sink="$internal_fallback"
            fi
        fi
    fi

    if [ -n "$restore_sink" ]; then
        if pactl set-default-sink "$restore_sink" >/dev/null 2>&1; then
            echo "Restored default sink: $restore_sink"
            pactl set-sink-mute "$restore_sink" 0 >/dev/null 2>&1 || true
        else
            echo "Warning: Failed to restore default sink '$restore_sink'."
            internal_fallback="$(pactl list sinks short | awk 'NR==1 { print $2; exit }')"
            if [ -n "$internal_fallback" ] && [ "$internal_fallback" != "$restore_sink" ]; then
                if pactl set-default-sink "$internal_fallback" >/dev/null 2>&1; then
                    echo "Recovered default sink with fallback: $internal_fallback"
                    pactl set-sink-mute "$internal_fallback" 0 >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi
}

run_cleanup_once() {
    local message="$1"

    if [ "$CLEANUP_DONE" = "1" ]; then
        return 0
    fi
    CLEANUP_DONE=1

    if [ -n "$message" ]; then
        echo "$message"
    fi
    
    # If we were using direct ALSA, ensure we restore the IEC958 status to "audio" (PCM)
    # This prevents the "Zombie State" where the receiver expects AC-3 but gets nothing.
    if [ "$USE_DIRECT_APLAY" = "1" ] && [ -n "$DIRECT_ALSA_APLAY_DEVICE" ]; then
        # Check if we can derive the IEC958 index from the device number
        local device_num="${DIRECT_ALSA_APLAY_DEVICE##*,}"
        local card_num="${DIRECT_ALSA_APLAY_DEVICE%%,*}"
        card_num="${card_num##hw:}"
        
        # We need to find the IEC958 control index again or use a saved one.
        # Ideally we should have saved it, but re-detecting is safer than assuming.
        if command -v iecset >/dev/null 2>&1; then
            echo "Restoring IEC958 status to 'audio' (PCM) for card $card_num, device $device_num..."
            # Try to restore using the same logic as setup
            local iec958_index=""
            if [ "$device_num" = "3" ]; then iec958_index=0; fi
            if [ "$device_num" = "7" ]; then iec958_index=1; fi
            if [ "$device_num" = "8" ]; then iec958_index=2; fi
            if [ "$device_num" = "9" ]; then iec958_index=3; fi
            
            if [ -n "$iec958_index" ]; then
                iecset -c "$card_num" -n "$iec958_index" audio on >/dev/null 2>&1 || true
            fi
        fi
    fi

    restore_runtime_audio_state
    echo "Killing children of $$"
    pkill -P $$ >/dev/null 2>&1 || true
}

configure_hdmi_passthrough() {
    local sink_name="$1"
    local sink_index="$2"
    local requested_sink_name="$sink_name"
    local live_index=""
    local sink_ref=""
    local loopback_backing=""
    local loopback_backing_normalized=""

    if [[ "$sink_name" == alsa_loopback_device.* ]]; then
        loopback_backing="${sink_name#alsa_loopback_device.}"
        loopback_backing_normalized="$(normalize_sink_name_for_ac3 "$loopback_backing")"

        live_index="$(wait_for_sink_index_by_name "$loopback_backing_normalized" 20 || true)"
        if [ -n "$live_index" ]; then
            sink_name="$loopback_backing_normalized"
            sink_index="$live_index"
            echo "Using physical sink '$sink_name' (Index: $sink_index) for passthrough setup."
        else
            live_index="$(wait_for_sink_index_by_name "$loopback_backing" 20 || true)"
            if [ -n "$live_index" ]; then
                sink_name="$loopback_backing"
                sink_index="$live_index"
                echo "Using physical sink '$sink_name' (Index: $sink_index) for passthrough setup."
            else
                echo "Warning: Selected sink '$requested_sink_name' is loopback and no physical backing sink is visible."
                echo "Expected backing sink like '$loopback_backing_normalized' (or '$loopback_backing')."
                echo "Falling back to loopback sink passthrough setup; this may be unstable."
                live_index="$(wait_for_sink_index_by_name "$requested_sink_name" 20 || true)"
                if [ -n "$live_index" ]; then
                    sink_name="$requested_sink_name"
                    sink_index="$live_index"
                fi
            fi
        fi
    else
        live_index="$(wait_for_sink_index_by_name "$sink_name" 20 || true)"
        if [ -n "$live_index" ]; then
            sink_index="$live_index"
        fi
    fi

    if [ -n "$sink_name" ] && [ -n "$sink_index" ]; then
        sink_ref="$sink_name"
        echo "Using live sink '$sink_name' (Index: $sink_index) for passthrough setup."
    elif [ -n "$sink_index" ]; then
        sink_ref="$sink_index"
        echo "Warning: Could not resolve sink by name '$sink_name'; using sink index '$sink_index'."
    else
        echo "Error: Could not resolve a valid sink for passthrough setup."
        pactl list sinks short || true
        return 1
    fi

    echo "Configuring sink formats and volume..."
    # pactl set-sink-formats requires a numeric sink index.
    sink_formats_ref="$sink_index"
    if [ -z "$sink_formats_ref" ]; then
        sink_formats_ref="$sink_ref"
    fi

    if ! pactl set-sink-formats "$sink_formats_ref" 'ac3-iec61937, format.rate = "[ 48000 ]"'; then
        echo "Warning: Exact AC3 format string failed, retrying multi-rate AC3 format..."
        if ! pactl set-sink-formats "$sink_formats_ref" 'ac3-iec61937, format.rate = "[ 32000, 44100, 48000 ]"'; then
            echo "Warning: Failed to set AC3 sink formats."
        fi
    fi

    pactl set-sink-volume "$sink_ref" 100% || true
    pactl set-sink-mute "$sink_ref" 0 || true
}

normalize_pw_ac3_live_levels() {
    echo "Normalizing pw-ac3-live node/stream volumes..."

    if pactl list sinks short | awk '$2=="pw-ac3-live-input" { found=1 } END { exit(found ? 0 : 1) }'; then
        pactl set-sink-volume "pw-ac3-live-input" 100% || true
        pactl set-sink-mute "pw-ac3-live-input" 0 || true
    else
        echo "Info: pw-ac3-live-input sink not present in pactl; skipping sink volume normalization."
    fi

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

    if [ "$PLAYBACK_MODE" = "native" ] || [ "${USE_DIRECT_APLAY:-0}" = "1" ]; then
        echo "Info: No PulseAudio sink-input for pw-ac3-live in mode '$PLAYBACK_MODE' (direct_alsa=${USE_DIRECT_APLAY:-0}); skipping sink-input volume normalization."
    else
        echo "Warning: Could not find pw-ac3-live playback sink-input; leaving stream volume unchanged."
    fi
}

sink_index_for_name() {
    local sink_name="$1"
    [ -n "$sink_name" ] || return 1
    pactl list sinks short | awk -v sink="$sink_name" '$2==sink {print $1; exit}'
}

normalize_sink_name_for_ac3() {
    local sink_name="$1"
    sink_name="${sink_name/hdmi-surround71/hdmi-stereo}"
    sink_name="${sink_name/hdmi-surround/hdmi-stereo}"
    echo "$sink_name"
}

wait_for_sink_index_by_name() {
    local sink_name="$1"
    local retries="${2:-20}"
    local idx=""
    [ -n "$sink_name" ] || return 1

    for _ in $(seq 1 "$retries"); do
        idx="$(sink_index_for_name "$sink_name" || true)"
        if [ -n "$idx" ]; then
            echo "$idx"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

count_sink_inputs_for_sink_name() {
    local sink_name="$1"
    local sink_index=""
    sink_index="$(sink_index_for_name "$sink_name" || true)"
    if [ -z "$sink_index" ]; then
        echo 0
        return 0
    fi
    pactl list sink-inputs short | awk -v idx="$sink_index" '$2==idx { c++ } END { print c+0 }'
}

check_graph_health() {
    local target_node="$1"

    local input_route_count
    input_route_count=$(pw-link -l | awk '
        {
            split($0, a, " -> ");
            if (length(a) != 2) {
                next;
            }
            split(a[2], dst_parts, ":");
            dst_node = dst_parts[1];
            if (dst_node == "pw-ac3-live-input") {
                c++;
            }
        }
        END { print c+0 }
    ')
    if [ "$input_route_count" -eq 0 ]; then
        local sink_input_count
        sink_input_count="$(count_sink_inputs_for_sink_name "pw-ac3-live-input")"
        if [ "$sink_input_count" -gt 0 ]; then
            echo "Detected $sink_input_count app sink-input(s) targeting pw-ac3-live-input (pactl view)."
        else
            echo "Warning: No app streams are currently routed into pw-ac3-live-input (encoder input is silent)."
            echo "Hint: start audio playback, then check app output device is 'AC-3 Encoder Input'."
        fi
    else
        echo "Detected $input_route_count app route(s) into pw-ac3-live-input."
    fi

    if [ -n "$target_node" ]; then
        local output_link_count
        output_link_count=$(pw-link -l | awk -v target="$target_node" '
            {
                split($0, a, " -> ");
                if (length(a) != 2) {
                    next;
                }
                split(a[1], src_parts, ":");
                split(a[2], dst_parts, ":");
                src_node = src_parts[1];
                dst_node = dst_parts[1];
                if (src_node == "pw-ac3-live-output" && dst_node == target) {
                    c++;
                }
            }
            END { print c+0 }
        ')
        if [ "$output_link_count" -eq 0 ]; then
            echo "Warning: No pw-ac3-live-output links detected toward '$target_node'."
        else
            echo "Detected $output_link_count pw-ac3-live-output link(s) toward '$target_node'."
        fi
    fi
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

launch_direct_aplay_pipeline() {
    local producer_cmd_var="$1"
    local aplay_device="$2"
    local producer_cmd=()
    local had_open_error=0

    eval "producer_cmd=(\"\${${producer_cmd_var}[@]}\")"

    if [ "$SHOW_RUNTIME_LOGS" = "1" ]; then
        (
            # Shrink pipe buffer to minimum (4096 bytes) using python3 fcntl
            # Shrink pipe buffer using dedicated shim script
            "${producer_cmd[@]}" 2> >(tee /tmp/pw-ac3-live.log >&2) | \
            "$(dirname "$0")/reduce_pipe_latency.py" | \
            aplay -D "$aplay_device" \
                --disable-resample --disable-format --disable-channels --disable-softvol \
                -v -t raw -f S16_LE -r 48000 -c 2 --buffer-time="$DIRECT_ALSA_BUFFER_TIME" --period-time="$DIRECT_ALSA_PERIOD_TIME" \
                2>&1 | tee /tmp/aplay.log
        ) &
    else
        (
            "${producer_cmd[@]}" 2>/tmp/pw-ac3-live.log | \
            "$(dirname "$0")/reduce_pipe_latency.py" | \
            aplay -D "$aplay_device" \
                --disable-resample --disable-format --disable-channels --disable-softvol \
                -v -t raw -f S16_LE -r 48000 -c 2 --buffer-time="$DIRECT_ALSA_BUFFER_TIME" --period-time="$DIRECT_ALSA_PERIOD_TIME" \
                > /tmp/aplay.log 2>&1
        ) &
    fi
    APP_PID=$!

    # Give aplay a moment to open the device before moving on.
    sleep 1
    if [ -f "/tmp/aplay.log" ] && grep -qi "audio open error" /tmp/aplay.log; then
        had_open_error=1
    fi

    if [ "$had_open_error" -eq 1 ]; then
        return 1
    fi
    return 0
}

pipewire_input_node_exists() {
    local node="$1"
    [ -n "$node" ] || return 1
    pw-link -i | awk -v node="$node" '
        {
            split($1, p, ":");
            if (p[1] == node) {
                found = 1;
                exit;
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

profile_suffix_to_alsa_device_number() {
    local suffix="$1"
    case "$suffix" in
        *"extra1") echo "7" ;;
        *"extra2") echo "8" ;;
        *"extra3") echo "9" ;;
        *) echo "3" ;;
    esac
}

hdmi_pin_to_pcm_device_number() {
    local pin="$1"
    [[ "$pin" =~ ^[0-9]+$ ]] || return 1
    if [ "$pin" -eq 0 ]; then
        echo "3"
    else
        # HDA HDMI convention: pin 1 -> device 7, pin 2 -> device 8, pin 3 -> device 9, ...
        echo $((pin + 6))
    fi
}

find_active_hdmi_device_from_eld() {
    local card_num="$1"
    local profile_suffix="$2"
    local base="/proc/asound/card${card_num}"
    local preferred_pin=""
    local file pin monitor_present eld_valid dev

    [ -d "$base" ] || return 1

    case "$profile_suffix" in
        *"extra1") preferred_pin="1" ;;
        *"extra2") preferred_pin="2" ;;
        *"extra3") preferred_pin="3" ;;
        *) preferred_pin="0" ;;
    esac

    # First pass: preferred pin from the profile suffix.
    for file in "$base"/eld#*.*; do
        [ -f "$file" ] || continue
        pin="${file##*eld#}"
        pin="${pin%%.*}"
        monitor_present="$(awk '/monitor_present/{print $2; exit}' "$file")"
        eld_valid="$(awk '/eld_valid/{print $2; exit}' "$file")"
        [ "$pin" = "$preferred_pin" ] || continue
        if [ "$monitor_present" = "1" ] && [ "$eld_valid" = "1" ]; then
            dev="$(hdmi_pin_to_pcm_device_number "$pin" || true)"
            if [ -n "$dev" ]; then
                echo "$dev"
                return 0
            fi
        fi
    done

    # Second pass: any active/valid HDMI ELD on this card.
    for file in "$base"/eld#*.*; do
        [ -f "$file" ] || continue
        pin="${file##*eld#}"
        pin="${pin%%.*}"
        monitor_present="$(awk '/monitor_present/{print $2; exit}' "$file")"
        eld_valid="$(awk '/eld_valid/{print $2; exit}' "$file")"
        if [ "$monitor_present" = "1" ] && [ "$eld_valid" = "1" ]; then
            dev="$(hdmi_pin_to_pcm_device_number "$pin" || true)"
            if [ -n "$dev" ]; then
                echo "$dev"
                return 0
            fi
        fi
    done

    return 1
}

normalize_profile_suffix_for_ac3() {
    local suffix="$1"
    # IEC61937 passthrough should prefer HDMI stereo profiles.
    case "$suffix" in
        hdmi-surround71*) echo "${suffix/hdmi-surround71/hdmi-stereo}" ;;
        hdmi-surround*) echo "${suffix/hdmi-surround/hdmi-stereo}" ;;
        *) echo "$suffix" ;;
    esac
}

card_name_to_pci_bdf() {
    local card_name="$1"
    local token=""

    [ -n "$card_name" ] || return 1
    token="${card_name#*pci-}"
    [ "$token" != "$card_name" ] || return 1

    # alsa_card.pci-0000_04_00.1 -> 0000:04:00.1
    token="${token%%.*}.${token##*.}"
    token="${token/_/:}"
    token="${token/_/:}"
    echo "$token"
}

find_alsa_card_number_for_pci_bdf() {
    local bdf="$1"
    local card_dir dev_path card_num

    [ -n "$bdf" ] || return 1
    for card_dir in /sys/class/sound/card*; do
        [ -d "$card_dir" ] || continue
        dev_path="$(readlink -f "$card_dir/device" 2>/dev/null || true)"
        if [ -n "$dev_path" ] && echo "$dev_path" | grep -q "$bdf"; then
            card_num="${card_dir##*card}"
            if [[ "$card_num" =~ ^[0-9]+$ ]]; then
                echo "$card_num"
                return 0
            fi
        fi
    done
    return 1
}

find_alsa_card_number_for_card_name() {
    local card_name="$1"
    local card_num=""
    local pci_bdf=""
    [ -n "$card_name" ] || return 1
    card_num="$(pactl list cards | awk -v target="$card_name" '
        $1=="Name:" && $2==target { in_card=1; next }
        in_card && $0 ~ /api\.alsa\.card/ {
            line = $0;
            gsub(/.*"/, "", line);
            gsub(/".*/, "", line);
            if (line ~ /^[0-9]+$/) {
                print line;
                exit;
            }
        }
        in_card && $0 ~ /alsa\.card/ && $0 !~ /alsa\.card_name/ {
            line = $0;
            gsub(/.*"/, "", line);
            gsub(/".*/, "", line);
            if (line ~ /^[0-9]+$/) {
                print line;
                exit;
            }
        }
        in_card && $1=="Name:" && $2!=target { exit }
    ')"
    if [ -n "$card_num" ]; then
        echo "$card_num"
        return 0
    fi

    pci_bdf="$(card_name_to_pci_bdf "$card_name" || true)"
    if [ -n "$pci_bdf" ]; then
        card_num="$(find_alsa_card_number_for_pci_bdf "$pci_bdf" || true)"
        if [ -n "$card_num" ]; then
            echo "$card_num"
            return 0
        fi
    fi

    return 1
}

find_alsa_device_number_for_sink_name() {
    local sink_name="$1"
    [ -n "$sink_name" ] || return 1
    pactl list sinks | awk -v target="$sink_name" '
        $1=="Name:" && $2==target { in_sink=1; next }
        in_sink && $0 ~ /alsa\.device/ {
            line = $0;
            gsub(/.*"/, "", line);
            gsub(/".*/, "", line);
            if (line ~ /^[0-9]+$/) {
                print line;
                exit;
            }
        }
        in_sink && $1=="Name:" && $2!=target { exit }
    '
}

alsa_card_id_from_number() {
    local card_num="$1"
    local id_path="/proc/asound/card${card_num}/id"
    [ -f "$id_path" ] || return 1
    head -n1 "$id_path"
}

hw_device_to_iec958_dev_index() {
    local hw_dev="$1"
    case "$hw_dev" in
        3) echo 0 ;;
        7) echo 1 ;;
        8) echo 2 ;;
        9) echo 3 ;;
        *) return 1 ;;
    esac
}

# Apply IEC958 Non-Audio bit for AC-3/DTS passthrough.
# Sets ALL IEC958 indices (0..3) to Non-Audio unconditionally.
# The HDA HDMI driver maps indices unpredictably, so brute-forcing
# all of them is the safest approach.
apply_iec958_non_audio() {
    local alsa_device="$1"     # e.g. hw:0,8
    local skip_iecset="$2"     # 1 = skip

    [ "$skip_iecset" = "1" ] && { echo "Skipping iecset Non-Audio configuration."; return 0; }
    command -v iecset >/dev/null 2>&1 || { echo "Warning: 'iecset' not found. Cannot force Non-Audio bit."; return 1; }

    local card_index applied=0
    card_index=$(echo "$alsa_device" | cut -d',' -f1 | sed 's/hw://')

    local mode_arg="audio off"
    local mode_desc="Non-Audio"
    if [ "${PW_AC3_PASSTHROUGH:-0}" = "1" ]; then
        mode_arg="audio on"
        mode_desc="PCM Audio (Passthrough Mode)"
    fi

    echo "Setting IEC958 to '$mode_desc' on ALL indices (0..3) for card $card_index..."
    for idx in 0 1 2 3; do
        # If passthrough, ensure "audio on"; if AC-3, ensure "audio off"
        if iecset -c "$card_index" -n "$idx" $mode_arg rate 48000 >/dev/null 2>&1; then
            echo "  index $idx: $mode_desc set."
            applied=1
        else
            echo "  index $idx: failed (may be locked or absent)."
        fi
    done

    if [ "$applied" -eq 0 ]; then
        echo "Warning: iecset could not apply non-audio mode on any index."
        return 1
    fi
    return 0
}

# Dump comprehensive audio system state for debugging.
# Usage: dump_audio_state "label" "card_num" "hw_device"
dump_audio_state() {
    local label="$1"
    local card_num="${2:-0}"
    local hw_device="${3:-}"
    echo ""
    echo "===== AUDIO STATE DUMP: $label ====="
    echo "--- Timestamp: $(date '+%H:%M:%S.%N') ---"

    # IEC958 controls (AES0 byte: 0x04=Audio/PCM, 0x06=Non-Audio)
    echo "--- IEC958 Playback Default (amixer, card $card_num) ---"
    amixer -c "$card_num" contents 2>/dev/null | awk '
        /numid=.*IEC958 Playback Default/ { printing=1; print; next }
        printing && /^ / { print; next }
        printing { printing=0 }
    ' || echo "  (amixer not available)"

    # IEC958 Playback Con* (per-connector: on HDA HDMI these override Default)
    echo "--- IEC958 Playback Con* (amixer, card $card_num) ---"
    amixer -c "$card_num" contents 2>/dev/null | awk '
        /numid=.*IEC958 Playback Con/ { printing=1; print; next }
        printing && /^ / { print; next }
        printing { printing=0 }
    ' || echo "  (none found)"

    # ALSA hw_params: what format did the driver actually negotiate?
    local hw_dev_idx="${hw_device##*,}"
    if [ -n "$hw_dev_idx" ] && [ -f "/proc/asound/card${card_num}/pcm${hw_dev_idx}p/sub0/hw_params" ]; then
        echo "--- /proc/asound/card${card_num}/pcm${hw_dev_idx}p/sub0/hw_params ---"
        cat "/proc/asound/card${card_num}/pcm${hw_dev_idx}p/sub0/hw_params"
    else
        echo "--- hw_params: device not open or path not found ---"
    fi

    # HDMI/DP Jack states
    echo "--- HDMI/DP Jack states (card $card_num) ---"
    amixer -c "$card_num" contents 2>/dev/null | awk '
        /numid=.*HDMI\/DP.*Jack/ { printing=1; print; next }
        printing && /^ / { print; next }
        printing { printing=0 }
    ' || echo "  (amixer not available)"

    # Active card profile
    echo "--- Active PipeWire card profile ---"
    pactl list cards short 2>/dev/null | head -5 || echo "  (pactl not available)"
    if command -v wpctl >/dev/null 2>&1; then
        wpctl status 2>/dev/null | grep -A2 -i "hdmi\|HDMI" | head -6 || true
    fi

    # Who holds /dev/snd/* open?
    echo "--- Processes using /dev/snd/* ---"
    fuser -v /dev/snd/* 2>&1 || echo "  (no processes or fuser unavailable)"

    # PipeWire sinks
    echo "--- PipeWire sinks ---"
    pactl list sinks short 2>/dev/null || echo "  (pactl not available)"

    # PipeWire sink-inputs
    echo "--- PipeWire sink-inputs ---"
    pactl list sink-inputs short 2>/dev/null || echo "  (pactl not available)"

    # aplay log tail
    if [ -f /tmp/aplay.log ]; then
        echo "--- /tmp/aplay.log (last 10 lines) ---"
        tail -10 /tmp/aplay.log
    fi

    # Live PCM stream status (CURRENT hw_ptr / appl_ptr — not the snapshot from -v)
    local hw_dev_idx2="${hw_device##*,}"
    if [ -n "$hw_dev_idx2" ] && [ -f "/proc/asound/card${card_num}/pcm${hw_dev_idx2}p/sub0/status" ]; then
        echo "--- LIVE PCM status (card${card_num}/pcm${hw_dev_idx2}p/sub0/status) ---"
        cat "/proc/asound/card${card_num}/pcm${hw_dev_idx2}p/sub0/status"
    fi

    # pw-ac3-live log tail
    if [ -f /tmp/pw-ac3-live.log ]; then
        echo "--- /tmp/pw-ac3-live.log (last 10 lines) ---"
        tail -10 /tmp/pw-ac3-live.log
    fi

    # ELD status for the specific device
    echo "--- ELD status (card $card_num) ---"
    for eld in /proc/asound/card${card_num}/eld#*; do
        [ -f "$eld" ] || continue
        local mon=$(grep 'monitor_present' "$eld" 2>/dev/null || true)
        local valid=$(grep 'eld_valid' "$eld" 2>/dev/null || true)
        echo "  $(basename $eld): $mon  $valid"
    done

    echo "===== END AUDIO STATE DUMP: $label ====="
    echo ""
}

build_iec958_aplay_device_from_hw() {
    local hw_device="$1"
    local card_num hw_dev card_id iec_dev_idx

    [[ "$hw_device" == hw:* ]] || return 1
    card_num="${hw_device#hw:}"
    card_num="${card_num%%,*}"
    hw_dev="${hw_device##*,}"

    card_id="$(alsa_card_id_from_number "$card_num" || true)"
    iec_dev_idx="$(hw_device_to_iec958_dev_index "$hw_dev" || true)"
    [ -n "$card_id" ] || return 1
    [ -n "$iec_dev_idx" ] || return 1

    echo "iec958:CARD=${card_id},DEV=${iec_dev_idx}"
}

build_hdmi_aplay_device_from_hw() {
    local hw_device="$1"
    local card_num hw_dev card_id hdmi_dev_idx

    [[ "$hw_device" == hw:* ]] || return 1
    card_num="${hw_device#hw:}"
    card_num="${card_num%%,*}"
    hw_dev="${hw_device##*,}"

    card_id="$(alsa_card_id_from_number "$card_num" || true)"
    hdmi_dev_idx="$(hw_device_to_iec958_dev_index "$hw_dev" || true)"
    [ -n "$card_id" ] || return 1
    [ -n "$hdmi_dev_idx" ] || return 1

    if [ -n "$DIRECT_ALSA_HDMI_AES_PARAMS" ]; then
        echo "hdmi:CARD=${card_id},DEV=${hdmi_dev_idx},${DIRECT_ALSA_HDMI_AES_PARAMS}"
    else
        echo "hdmi:CARD=${card_id},DEV=${hdmi_dev_idx}"
    fi
}

aplay_supports_named_device() {
    local device="$1"
    [ -n "$device" ] || return 1
    command -v aplay >/dev/null 2>&1 || return 1
    aplay -L 2>/dev/null | awk -v target="$device" '$0==target { found=1; exit } END { exit(found ? 0 : 1) }'
}

select_direct_alsa_aplay_device() {
    local hw_device="$1"
    local selected=""
    local override="${PW_AC3_DIRECT_ALSA_APLAY_DEVICE:-}"
    local iec958_candidate=""
    local hdmi_candidate=""

    if [ -n "$override" ]; then
        selected="$override"
        if [[ "$override" == iec958:* ]] && ! aplay_supports_named_device "$override"; then
            echo "Warning: PW_AC3_DIRECT_ALSA_APLAY_DEVICE='$override' is not advertised by aplay -L; using override as requested." >&2
        fi
        echo "Using PW_AC3_DIRECT_ALSA_APLAY_DEVICE override: $selected" >&2
    fi

    if [ -z "$selected" ] && [ "$DIRECT_ALSA_USE_HDMI_PLUGIN" = "1" ]; then
        hdmi_candidate="$(build_hdmi_aplay_device_from_hw "$hw_device" || true)"
        if [ -n "$hdmi_candidate" ]; then
            selected="$hdmi_candidate"
            echo "Using HDMI ALSA plugin device for passthrough: $selected" >&2
        fi
    fi

    if [ -z "$selected" ] && [ "$DIRECT_ALSA_AUTO_IEC958" = "1" ]; then
        iec958_candidate="$(build_iec958_aplay_device_from_hw "$hw_device" || true)"
        if [ -n "$iec958_candidate" ]; then
            if aplay_supports_named_device "$iec958_candidate"; then
                selected="$iec958_candidate"
                echo "Using IEC958 ALSA device for passthrough: $selected" >&2
            else
                echo "Warning: Auto-derived IEC958 ALSA device '$iec958_candidate' is not advertised by aplay -L; falling back to '$hw_device'." >&2
            fi
        fi
    fi

    if [ -z "$selected" ]; then
        selected="$hw_device"
    fi

    if [ "${PW_AC3_DIRECT_ALSA_USE_PLUG:-0}" = "1" ] && [[ "$selected" == hw:* ]]; then
        selected="plughw:${selected#hw:}"
    fi

    echo "$selected"
}

find_any_active_hdmi_hw_device_from_eld() {
    local profile_suffix="$1"
    local preferred_pin=""
    local card_dir card_num file pin monitor_present eld_valid dev

    case "$profile_suffix" in
        *"extra1") preferred_pin="1" ;;
        *"extra2") preferred_pin="2" ;;
        *"extra3") preferred_pin="3" ;;
        *) preferred_pin="" ;;
    esac

    # First pass: prefer ELD pin matching the requested HDMI extra suffix.
    if [ -n "$preferred_pin" ]; then
        for card_dir in /proc/asound/card*; do
            [ -d "$card_dir" ] || continue
            card_num="${card_dir##*card}"
            for file in "$card_dir"/eld#*.*; do
                [ -f "$file" ] || continue
                pin="${file##*eld#}"
                pin="${pin%%.*}"
                [ "$pin" = "$preferred_pin" ] || continue
                monitor_present="$(awk '/monitor_present/{print $2; exit}' "$file")"
                eld_valid="$(awk '/eld_valid/{print $2; exit}' "$file")"
                if [ "$monitor_present" = "1" ] && [ "$eld_valid" = "1" ]; then
                    dev="$(hdmi_pin_to_pcm_device_number "$pin" || true)"
                    if [ -n "$dev" ]; then
                        echo "${card_num},${dev}"
                        return 0
                    fi
                fi
            done
        done
    fi

    # Second pass: any active/valid ELD across cards.
    for card_dir in /proc/asound/card*; do
        [ -d "$card_dir" ] || continue
        card_num="${card_dir##*card}"
        for file in "$card_dir"/eld#*.*; do
            [ -f "$file" ] || continue
            pin="${file##*eld#}"
            pin="${pin%%.*}"
            monitor_present="$(awk '/monitor_present/{print $2; exit}' "$file")"
            eld_valid="$(awk '/eld_valid/{print $2; exit}' "$file")"
            if [ "$monitor_present" = "1" ] && [ "$eld_valid" = "1" ]; then
                dev="$(hdmi_pin_to_pcm_device_number "$pin" || true)"
                if [ -n "$dev" ]; then
                    echo "${card_num},${dev}"
                    return 0
                fi
            fi
        done
    done

    return 1
}

log_eld_probe_status() {
    local file pin monitor_present eld_valid
    for file in /proc/asound/card*/eld#*.*; do
        [ -f "$file" ] || continue
        pin="${file##*eld#}"
        pin="${pin%%.*}"
        monitor_present="$(awk '/monitor_present/{print $2; exit}' "$file")"
        eld_valid="$(awk '/eld_valid/{print $2; exit}' "$file")"
        echo "Info: ELD probe ${file} pin=${pin} monitor_present=${monitor_present:-?} eld_valid=${eld_valid:-?}" >&2
    done
}

resolve_direct_alsa_hw_device() {
    local sink_name="$1"
    local card_name="$2"
    local profile_suffix="$3"

    if [ -n "$DIRECT_ALSA_DEVICE_OVERRIDE" ]; then
        echo "Info: PW_AC3_DIRECT_ALSA_DEVICE override is set ('$DIRECT_ALSA_DEVICE_OVERRIDE'); skipping ELD/sink auto-detection." >&2
        echo "$DIRECT_ALSA_DEVICE_OVERRIDE"
        return 0
    fi

    local alsa_card_num=""
    local alsa_device_num=""
    local preferred_profile_device=""
    local global_eld_pair=""
    local global_eld_card=""
    local global_eld_device=""

    alsa_card_num="$(find_alsa_card_number_for_card_name "$card_name" || true)"
    if [ -n "$alsa_card_num" ]; then
        echo "Info: Resolved ALSA card number '$alsa_card_num' for '$card_name'." >&2
    fi

    preferred_profile_device="$(profile_suffix_to_alsa_device_number "$profile_suffix")"

    if [ -n "$alsa_card_num" ]; then
        alsa_device_num="$(find_active_hdmi_device_from_eld "$alsa_card_num" "$profile_suffix" || true)"
        if [ -n "$alsa_device_num" ]; then
            echo "Info: Selected ALSA device from card-local ELD monitor detection (${alsa_device_num})." >&2
        else
            echo "Warning: No active HDMI ELD monitor detected on ALSA card $alsa_card_num." >&2
        fi
    fi

    if [ -z "$alsa_device_num" ]; then
        alsa_device_num="$(find_alsa_device_number_for_sink_name "$sink_name" || true)"
        if [ -n "$alsa_device_num" ]; then
            echo "Info: Selected ALSA device from sink metadata ($alsa_device_num)." >&2
        fi
    fi

    if [ -z "$alsa_device_num" ] && [ -n "$preferred_profile_device" ]; then
        alsa_device_num="$preferred_profile_device"
        echo "Info: Could not resolve ALSA device from ELD/sink metadata; using profile-based fallback ($alsa_device_num)." >&2
    fi

    if [ -z "$alsa_card_num" ] || [ -z "$alsa_device_num" ]; then
        global_eld_pair="$(find_any_active_hdmi_hw_device_from_eld "$profile_suffix" || true)"
        if [ -n "$global_eld_pair" ]; then
            global_eld_card="${global_eld_pair%%,*}"
            global_eld_device="${global_eld_pair##*,}"
            [ -n "$alsa_card_num" ] || alsa_card_num="$global_eld_card"
            [ -n "$alsa_device_num" ] || alsa_device_num="$global_eld_device"
            echo "Info: Selected ALSA hw device from global ELD scan (card=${global_eld_card}, device=${global_eld_device})." >&2
        else
            echo "Warning: No active HDMI ELD found in global scan." >&2
            log_eld_probe_status
        fi
    fi

    if [ -z "$alsa_card_num" ]; then
        echo "Warning: Could not resolve ALSA card number for '$card_name'; defaulting to card 0." >&2
        echo "Hint: set PW_AC3_DIRECT_ALSA_DEVICE=hw:<card>,<device> to override." >&2
        alsa_card_num="0"
    fi

    if [ -z "$alsa_device_num" ]; then
        alsa_device_num="$preferred_profile_device"
        echo "Info: Could not resolve ALSA device number from all sources; using profile-based fallback ($alsa_device_num)." >&2
    fi

    if [ -n "$preferred_profile_device" ] && [ "$alsa_device_num" != "$preferred_profile_device" ]; then
        echo "Warning: Resolved ALSA device (${alsa_device_num}) does not match profile-derived device (${preferred_profile_device}) for '${profile_suffix}'." >&2
        echo "Hint: if silent, try PW_AC3_DIRECT_ALSA_DEVICE=hw:${alsa_card_num},${preferred_profile_device}" >&2
        if [ "$DIRECT_ALSA_FORCE_PROFILE_DEVICE" = "1" ]; then
            echo "Info: Forcing direct ALSA device to profile-derived device (${preferred_profile_device}) because PW_AC3_DIRECT_ALSA_FORCE_PROFILE_DEVICE=1." >&2
            alsa_device_num="$preferred_profile_device"
        fi
    fi

    echo "hw:${alsa_card_num},${alsa_device_num}"
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
# Unload any previously loaded direct ALSA sink module to prevent conflicts and ensure clean state.
# Identify the module by the sink_name argument.
pactl list short modules | grep "sink_name=pw_ac3_direct_hdmi" | cut -f1 | xargs -r -I{} pactl unload-module {} >/dev/null 2>&1 || true
sleep 1
ORIGINAL_DEFAULT_SINK="$(pactl get-default-sink 2>/dev/null || true)"
if [ -n "$ORIGINAL_DEFAULT_SINK" ]; then
  echo "Original default sink: $ORIGINAL_DEFAULT_SINK"
fi
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
CONNECT_TARGET_PATTERN="$SINK_NAME"
APP_TARGET_NAME="$SINK_NAME"
LOOPBACK_FALLBACK_TARGET=""
echo "Selected Sink: $SINK_NAME (Index: $SINK_INDEX)"

if echo "$SINK_NAME" | grep -q "loopback"; then
  LOOPBACK_FALLBACK_TARGET="$SINK_NAME"
  LOOPBACK_BACKING_SINK="${SINK_NAME#alsa_loopback_device.}"
  CONNECT_TARGET_PATTERN="$LOOPBACK_BACKING_SINK"
  if [ -z "$TARGET_SINK_OVERRIDE" ]; then
    PHYSICAL_LINE=$(pactl list sinks short | awk -v n="$LOOPBACK_BACKING_SINK" '$2==n {print; exit}')
    if [ -n "$PHYSICAL_LINE" ]; then
      SINK_INDEX=$(echo "$PHYSICAL_LINE" | awk '{print $1}')
      SINK_NAME=$(echo "$PHYSICAL_LINE"  | awk '{print $2}')
      CONNECT_TARGET_PATTERN="$SINK_NAME"
      echo "Loopback sink detected. Switching to physical sink: $SINK_NAME (Index: $SINK_INDEX)"
    else
      AUTO_APP_TARGET_FROM_CONNECT=0
      echo "Loopback sink detected and no physical sink entry found in pactl."
      echo "Will keep loopback as stream target and try backing pattern for port links: $CONNECT_TARGET_PATTERN"
    fi
  else
    echo "Warning: Override sink appears loopback-based. Passthrough may be choppy/silent."
  fi
fi

if [ -n "$CONNECT_TARGET_OVERRIDE" ]; then
  CONNECT_TARGET_PATTERN="$CONNECT_TARGET_OVERRIDE"
  echo "Using PW_AC3_CONNECT_TARGET override for link step: $CONNECT_TARGET_PATTERN"
fi

if [ -n "$APP_TARGET_OVERRIDE" ]; then
  APP_TARGET_NAME="$APP_TARGET_OVERRIDE"
  echo "Using PW_AC3_APP_TARGET override for app --target: $APP_TARGET_NAME"
elif [ "$AUTO_APP_TARGET_FROM_CONNECT" = "1" ] && pipewire_input_node_exists "$CONNECT_TARGET_PATTERN"; then
  # Prefer targeting the exact node we are going to link to when available.
  APP_TARGET_NAME="$CONNECT_TARGET_PATTERN"
  echo "Using app --target node: $APP_TARGET_NAME"
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
  DERIVED_CARD_NAME=$(echo "$SINK_NAME" | sed 's/^alsa_loopback_device\.//; s/^alsa_output\./alsa_card./; s/\.hdmi.*$//')
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
  ORIGINAL_CARD_PROFILE=$(
    pactl list cards | awk -v c="$CARD_NAME" '
      $1=="Name:" && $2==c {found=1; next}
      found && $1=="Active" && $2=="Profile:" {print $3; exit}
      found && $1=="Name:" && $2!=c {exit}
    '
  )
  if [ -n "$ORIGINAL_CARD_PROFILE" ]; then
    RESTORE_PROFILE="$ORIGINAL_CARD_PROFILE"
    echo "Original active card profile: $ORIGINAL_CARD_PROFILE"
  fi
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
  # Fallback: extract from sink name (e.g. ...hdmi-stereo-extra2) if not found in properties
  if [ -z "$PROFILE_SUFFIX" ]; then
      PROFILE_SUFFIX="${SINK_NAME##*.}"
      echo "derived profile suffix: $PROFILE_SUFFIX"
  fi

  if [ -n "$PROFILE_SUFFIX" ]; then
    NORMALIZED_PROFILE_SUFFIX="$(normalize_profile_suffix_for_ac3 "$PROFILE_SUFFIX")"
    if [ "$NORMALIZED_PROFILE_SUFFIX" != "$PROFILE_SUFFIX" ]; then
      echo "Adjusting HDMI profile suffix for AC-3 passthrough: $PROFILE_SUFFIX -> $NORMALIZED_PROFILE_SUFFIX"
      PROFILE_SUFFIX="$NORMALIZED_PROFILE_SUFFIX"
    fi

    # Find an exact profile token on that card containing output:<suffix>
    PROFILE_NAME=$(
      pactl list cards | sed -n "/Name: $CARD_NAME/,/Active Profile/p" \
        | awk -v suf="$PROFILE_SUFFIX" '$1 ~ ("output:"suf) {gsub(/:$/,"",$1); print $1; exit}'
    )

    # Fallback
    [ -z "$PROFILE_NAME" ] && PROFILE_NAME="output:$PROFILE_SUFFIX"
    RESTORE_PROFILE="$PROFILE_NAME"

    echo "Setting card profile: $PROFILE_NAME"
    if ! pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME"; then
      echo "Warning: Failed to set card profile."
      echo "=== Debug Card Info ==="
      pactl list cards
      echo "======================="
      if [ -n "$ORIGINAL_CARD_PROFILE" ]; then
        RESTORE_PROFILE="$ORIGINAL_CARD_PROFILE"
      fi
    else
      echo "Will restore card profile to: $RESTORE_PROFILE"
    fi
    
    # Give PulseAudio/PipeWire a moment to bring up the new sink nodes
    sleep 2
  else
    echo "Warning: Could not read device.profile.name; skipping profile set."
  fi
fi

# 3b. If we were on a loopback, check if the physical sink appeared after profile switch
# 3b. If we were on a loopback, check if the physical sink appeared after profile switch
if [ -n "$LOOPBACK_FALLBACK_TARGET" ]; then
  echo "Re-checking for physical HDMI sink after profile update..."
  NEW_HDMI_LINE=$(find_best_hdmi_sink_line)
  
  # Determine if we found a VALID physical sink (not loopback)
  FOUND_PHYSICAL_SINK=0
  if [ -n "$NEW_HDMI_LINE" ]; then
      NEW_SINK_NAME=$(echo "$NEW_HDMI_LINE" | awk '{print $2}')
      if ! echo "$NEW_SINK_NAME" | grep -q "loopback"; then
          FOUND_PHYSICAL_SINK=1
      fi
  fi

  if [ "$FOUND_PHYSICAL_SINK" -eq 1 ]; then
      # CASE 1: Success - Physical sink appeared
      echo "Found physical sink: $NEW_SINK_NAME. Switching away from loopback."
      SINK_INDEX=$(echo "$NEW_HDMI_LINE" | awk '{print $1}')
      SINK_NAME="$NEW_SINK_NAME"
      APP_TARGET_NAME="$SINK_NAME"
      CONNECT_TARGET_PATTERN="$SINK_NAME"
      LOOPBACK_FALLBACK_TARGET=""
      AUTO_APP_TARGET_FROM_CONNECT=1


  else
      if [ "$DIRECT_ALSA_FALLBACK" = "1" ]; then
          # CASE 3: Failure - Physical sink hidden/busy. Optional direct ALSA fallback.
          echo "Loopback detected and physical sink is hidden/busy. Attempting Direct ALSA Sink takeover (PW_AC3_DIRECT_ALSA_FALLBACK=1)..."

          DIRECT_ALSA_DEVICE="$(resolve_direct_alsa_hw_device "$SINK_NAME" "$CARD_NAME" "$PROFILE_SUFFIX")"
          DIRECT_ALSA_CARD_NUM="${DIRECT_ALSA_DEVICE#hw:}"
          DIRECT_ALSA_CARD_NUM="${DIRECT_ALSA_CARD_NUM%%,*}"
          echo "Resolved direct ALSA device: '$DIRECT_ALSA_DEVICE' (profile '$PROFILE_SUFFIX')"
          if [ -n "$DIRECT_ALSA_DEVICE_OVERRIDE" ]; then
              echo "Using PW_AC3_DIRECT_ALSA_DEVICE override."
          fi
          
          # 1. Optionally disable profile to free the device.
          # Keeping the HDMI profile active tends to preserve output routing on some setups.
          if [ "$DIRECT_ALSA_DISABLE_PROFILE" = "1" ]; then
              echo "Disabling card profile '$PROFILE_NAME' to free hardware device (PW_AC3_DIRECT_ALSA_DISABLE_PROFILE=1)..."
              if [ -z "$RESTORE_PROFILE" ] && [ -n "$PROFILE_NAME" ]; then
                  RESTORE_PROFILE="$PROFILE_NAME"
              fi
              if [ -n "$RESTORE_PROFILE" ]; then
                  echo "Card profile will be restored to '$RESTORE_PROFILE' on exit."
              fi
              pactl set-card-profile "$CARD_NAME" off
              sleep 2
          else
              echo "Keeping card profile '$PROFILE_NAME' active for direct ALSA playback (PW_AC3_DIRECT_ALSA_DISABLE_PROFILE=0)."
          fi
          
          # 2. Use aplay directly (bypass Pulse/PipeWire sink)
          if command -v aplay >/dev/null 2>&1; then
              echo "Using direct 'aplay' to hardware device: $DIRECT_ALSA_DEVICE"
              USE_DIRECT_APLAY=1
              EXPLICIT_ALSA_DEVICE="$DIRECT_ALSA_DEVICE"
              
              # Update cleanup trap to restore profile
              trap 'run_cleanup_once "Cleaning up..."; exit' INT TERM EXIT
          else
              echo "Error: 'aplay' not found. Cannot proceed with direct ALSA takeover."
              restore_runtime_audio_state
              exit 1
          fi
      else
          echo "Loopback detected and physical sink is hidden/busy."
          echo "Keeping PipeWire loopback path (PW_AC3_DIRECT_ALSA_FALLBACK=0)."
          echo "Set PW_AC3_DIRECT_ALSA_FALLBACK=1 to force direct ALSA fallback."
      fi
  fi
fi

if [ -n "$CONNECT_TARGET_OVERRIDE" ]; then
      LOOPBACK_FALLBACK_TARGET=""
      AUTO_APP_TARGET_FROM_CONNECT=1
  fi

# Loopback-only path is typically less stable than physical HDMI nodes.
# If user did not override the output buffer, bias for stability.
if [ -n "$LOOPBACK_FALLBACK_TARGET" ] && [ "$USE_DIRECT_APLAY" != "1" ]; then
    if [ -z "${PW_AC3_BUFFER_SIZE+x}" ] && [ "$effective_buffer_size" -lt 24576 ]; then
        echo "Loopback-only path detected: increasing input buffer to 24576 frames for stability."
        effective_buffer_size=24576
    fi
    if [ -z "${PW_AC3_OUTPUT_BUFFER_SIZE+x}" ] && [ "$effective_output_buffer_size" -lt 24576 ]; then
        echo "Loopback-only path detected: increasing output buffer to 24576 frames for stability."
        effective_output_buffer_size=24576
    fi
    if [ -z "${PW_AC3_FFMPEG_CHUNK_FRAMES+x}" ] && [ "$LOW_LATENCY_CHUNK_FRAMES" -gt 512 ]; then
        echo "Loopback-only path detected: reducing ffmpeg chunk frames to 512 to smooth feeder writes."
        LOW_LATENCY_CHUNK_FRAMES=512
    fi
    # Loopback paths can run at very large graph quantums unless forced.
    if command -v pw-metadata >/dev/null 2>&1; then
        FORCE_QUANTUM_FRAMES="${LOW_LATENCY_NODE_LATENCY%%/*}"
        if [[ "$FORCE_QUANTUM_FRAMES" =~ ^[0-9]+$ ]] && [ "$FORCE_QUANTUM_FRAMES" -gt 0 ]; then
            echo "Requesting PipeWire clock.force-quantum=${FORCE_QUANTUM_FRAMES} and clock.force-rate=48000."
            if pw-metadata -n settings 0 clock.force-quantum "$FORCE_QUANTUM_FRAMES" >/dev/null 2>&1; then
                PW_CLOCK_FORCE_APPLIED=1
                pw-metadata -n settings 0 clock.force-rate 48000 >/dev/null 2>&1 || true
            else
                echo "Warning: Failed to apply PipeWire clock.force-quantum metadata."
            fi
        fi
    fi
fi

case "$PLAYBACK_MODE" in
    native|stdout)
        ;;
    *)
        echo "Warning: Unsupported PW_AC3_PLAYBACK_MODE='$PLAYBACK_MODE'. Falling back to 'native'."
        PLAYBACK_MODE="native"
        ;;
esac

case "$SHOW_RUNTIME_LOGS" in
    0|1)
        ;;
    *)
        echo "Warning: Unsupported PW_AC3_SHOW_RUNTIME_LOGS='$SHOW_RUNTIME_LOGS'. Falling back to 0."
        SHOW_RUNTIME_LOGS=0
        ;;
esac

case "$DIRECT_ALSA_FALLBACK" in
    0|1)
        ;;
    *)
        echo "Warning: Unsupported PW_AC3_DIRECT_ALSA_FALLBACK='$DIRECT_ALSA_FALLBACK'. Falling back to 0."
        DIRECT_ALSA_FALLBACK=0
        ;;
esac

# 4. Configure Sink Formats (AC3 Passthrough) & Volume
if [ "$USE_DIRECT_APLAY" != "1" ]; then
    configure_hdmi_passthrough "$SINK_NAME" "$SINK_INDEX"
fi

# 5. Launch Application
echo "Launching pw-ac3-live..."
PROFILE_LATENCY_ARGS=()
if [ "$ENABLE_LATENCY_PROFILE" = "1" ]; then
    echo "Latency profiling enabled."
    PROFILE_LATENCY_ARGS+=(--profile-latency)
fi

OUTPUT_BUFFER_ARGS=()
echo "Using effective buffers: input=${effective_buffer_size} output=${effective_output_buffer_size} frames"
echo "Using encoder cadence: node_latency=${LOW_LATENCY_NODE_LATENCY} ffmpeg_chunk_frames=${LOW_LATENCY_CHUNK_FRAMES} ffmpeg_thread_queue=${LOW_LATENCY_THREAD_QUEUE}"
OUTPUT_BUFFER_ARGS+=(--output-buffer-size "$effective_output_buffer_size")

if [ -x "$DEV_BIN" ]; then
    echo "Using local release binary: $DEV_BIN"
elif [ -x "$APP_BIN" ]; then
    echo "Using packaged binary: $APP_BIN"
    echo "Hint: build local release binary at '$DEV_BIN' to run latest workspace fixes."
    USE_PACKAGED_BINARY=1
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

APP_CMD=(
    env
    "PIPEWIRE_LATENCY=$LOW_LATENCY_NODE_LATENCY"
    "PIPEWIRE_QUANTUM=$LOW_LATENCY_NODE_LATENCY"
    "PIPEWIRE_RATE=48000"
    RUST_LOG=info
)
if [ "$USE_PACKAGED_BINARY" = "1" ]; then
    APP_CMD+=("$APP_BIN")
elif [ -x "$DEV_BIN" ]; then
    APP_CMD+=("$DEV_BIN")
else
    APP_CMD+=(cargo run --release --)
fi

    PASSTHROUGH_ARGS=()
    if [ "${PW_AC3_PASSTHROUGH:-0}" = "1" ]; then
        echo "WARNING: Enabling passthrough mode (No Encoding)."
        PASSTHROUGH_ARGS=(--passthrough)
    fi

COMMON_ARGS=(
    --buffer-size "$effective_buffer_size"
    --latency "$LOW_LATENCY_NODE_LATENCY"
    --ffmpeg-thread-queue-size "$LOW_LATENCY_THREAD_QUEUE"
    --ffmpeg-chunk-frames "$LOW_LATENCY_CHUNK_FRAMES"
    "${OUTPUT_BUFFER_ARGS[@]}"
    "${PROFILE_LATENCY_ARGS[@]}"
    "${PASSTHROUGH_ARGS[@]}"
)

if [ "$USE_DIRECT_APLAY" = "1" ]; then
    # Direct ALSA Playback (Exclusive Mode)
    PRODUCER_CMD=("${APP_CMD[@]}" --target "" --stdout "${COMMON_ARGS[@]}")
    DIRECT_ALSA_APLAY_DEVICE="$(select_direct_alsa_aplay_device "$EXPLICIT_ALSA_DEVICE")"
    DIRECT_ALSA_USED_PROFILE_OFF_RETRY=0
    DIRECT_ALSA_HW_FALLBACK_DEVICE="$EXPLICIT_ALSA_DEVICE"
    if [ "${PW_AC3_DIRECT_ALSA_USE_PLUG:-0}" = "1" ] && [[ "$DIRECT_ALSA_HW_FALLBACK_DEVICE" == hw:* ]]; then
        DIRECT_ALSA_HW_FALLBACK_DEVICE="plughw:${DIRECT_ALSA_HW_FALLBACK_DEVICE#hw:}"
    fi
    echo "Direct ALSA Command: aplay -D ${DIRECT_ALSA_APLAY_DEVICE} -v ..."

        # Ensure hardware volume is unmuted (critical when bypassing PipeWire)
        if command -v amixer >/dev/null 2>&1; then
            ALSA_CARD_INDEX=$(echo "$EXPLICIT_ALSA_DEVICE" | cut -d',' -f1 | sed 's/hw://')
            echo "Unmuting ALSA card $ALSA_CARD_INDEX..."
            # Try common controls
            amixer -c "$ALSA_CARD_INDEX" set Master unmute 100% >/dev/null 2>&1 || true
            amixer -c "$ALSA_CARD_INDEX" set PCM unmute 100% >/dev/null 2>&1 || true
            # Unmute all common IEC958 switch variants (index mapping differs by HDMI port).
            amixer -c "$ALSA_CARD_INDEX" set IEC958 unmute >/dev/null 2>&1 || true
            for IEC958_CTL in 'IEC958,1' 'IEC958,2' 'IEC958,3'; do
                amixer -c "$ALSA_CARD_INDEX" set "$IEC958_CTL" unmute >/dev/null 2>&1 || true
            done
            if [ "$SHOW_RUNTIME_LOGS" = "1" ]; then
                echo "ALSA IEC958 switch state (post-unmute):"
                amixer -c "$ALSA_CARD_INDEX" scontents 2>/dev/null | awk '
                    /^Simple mixer control / { current_ctrl = ($0 ~ /IEC958/ ? 1 : 0); if (current_ctrl) print; next }
                    current_ctrl && /Playback Switch/ { print }
                ' || true
            fi
        fi

    # ====================================================================
    # DIRECT ALSA LAUNCH STRATEGY
    #
    # PipeWire locks the IEC958 controls (rw--l---) while the card
    # profile is active.  iecset cannot set Non-Audio on the correct
    # index until the lock is released.  Therefore:
    #
    #   1. Disable the card profile  →  releases ALSA device + IEC958 lock
    #   2. Wait for PipeWire to fully release /dev/snd/pcmC*D*p
    #   3. Apply IEC958 Non-Audio    →  now succeeds on the correct index
    #   4. Launch aplay              →  device is free, IEC958 is correct
    # ====================================================================

    ALSA_CARD_INDEX_DIAG=$(echo "$EXPLICIT_ALSA_DEVICE" | cut -d',' -f1 | sed 's/hw://')

    # Step 1: Disable the card profile to release the ALSA device and
    #         the IEC958 control lock.
    if [ "$DIRECT_ALSA_DISABLE_PROFILE" != "1" ] && [ -n "$CARD_NAME" ] && [ -n "$PROFILE_NAME" ]; then
        echo "Disabling card profile '${PROFILE_NAME}' to release ALSA device and IEC958 lock..."
        if [ -z "$RESTORE_PROFILE" ]; then
            RESTORE_PROFILE="$PROFILE_NAME"
        fi
        pactl set-card-profile "$CARD_NAME" off >/dev/null 2>&1 || true
        DIRECT_ALSA_USED_PROFILE_OFF_RETRY=1
    fi

    # Step 2: Wait for PipeWire to asynchronously release /dev/snd/*
    echo "Waiting for PipeWire to release device..."
    RETRY_DELAYS=(1 2 3 5)
    DEVICE_FREE=0
    for WAIT_DELAY in "${RETRY_DELAYS[@]}"; do
        sleep "$WAIT_DELAY"
        if ! fuser "/dev/snd/pcmC${ALSA_CARD_INDEX_DIAG}D${EXPLICIT_ALSA_DEVICE##*,}p" >/dev/null 2>&1; then
            echo "Device released after ${WAIT_DELAY}s."
            DEVICE_FREE=1
            break
        fi
        echo "Device still busy, waiting ${WAIT_DELAY}s more..."
    done
    if [ "$DEVICE_FREE" -eq 0 ]; then
        echo "Warning: Device may still be held; proceeding anyway."
    fi

    # Clear stale logs from previous runs so diagnostic dumps show fresh data.
    : > /tmp/aplay.log 2>/dev/null || true
    : > /tmp/pw-ac3-live.log 2>/dev/null || true

    dump_audio_state "AFTER-PROFILE-OFF-DEVICE-FREE" "$ALSA_CARD_INDEX_DIAG" "$EXPLICIT_ALSA_DEVICE"

    # Step 3: Apply IEC958 Non-Audio (now that the lock is released)
    apply_iec958_non_audio "$EXPLICIT_ALSA_DEVICE" "$DIRECT_ALSA_SKIP_IECSET"
    dump_audio_state "AFTER-IECSET" "$ALSA_CARD_INDEX_DIAG" "$EXPLICIT_ALSA_DEVICE"

    # Step 4: Launch aplay
    if ! launch_direct_aplay_pipeline PRODUCER_CMD "$DIRECT_ALSA_APLAY_DEVICE"; then
        dump_audio_state "APLAY-OPEN-FAILED" "$ALSA_CARD_INDEX_DIAG" "$EXPLICIT_ALSA_DEVICE"
        if [ "$DIRECT_ALSA_APLAY_DEVICE" != "$DIRECT_ALSA_HW_FALLBACK_DEVICE" ]; then
            echo "Warning: aplay failed to open '$DIRECT_ALSA_APLAY_DEVICE'; retrying with fallback '$DIRECT_ALSA_HW_FALLBACK_DEVICE'."
            kill "$APP_PID" >/dev/null 2>&1 || true
            wait "$APP_PID" >/dev/null 2>&1 || true
            DIRECT_ALSA_APLAY_DEVICE="$DIRECT_ALSA_HW_FALLBACK_DEVICE"
            : > /tmp/aplay.log 2>/dev/null || true
            : > /tmp/pw-ac3-live.log 2>/dev/null || true
            if ! launch_direct_aplay_pipeline PRODUCER_CMD "$DIRECT_ALSA_APLAY_DEVICE"; then
                echo "Error: aplay fallback device '$DIRECT_ALSA_APLAY_DEVICE' also failed."
                echo "=== aplay startup log ==="
                cat /tmp/aplay.log
                echo "========================="
                exit 1
            fi
        else
            echo "Error: aplay failed to open direct ALSA device '$DIRECT_ALSA_APLAY_DEVICE'."
            echo "Hint: set PW_AC3_DIRECT_ALSA_APLAY_DEVICE or override PW_AC3_DIRECT_ALSA_DEVICE."
            echo "=== aplay startup log ==="
            cat /tmp/aplay.log
            echo "========================="
            exit 1
        fi
    fi
    dump_audio_state "APLAY-LAUNCHED" "$ALSA_CARD_INDEX_DIAG" "$EXPLICIT_ALSA_DEVICE"

    if [ "$DIRECT_ALSA_USED_PROFILE_OFF_RETRY" = "1" ] && [ "$DIRECT_ALSA_RESTORE_PROFILE_AFTER_OPEN" = "1" ] && [ -n "$CARD_NAME" ] && [ -n "$PROFILE_NAME" ]; then
        echo "Re-applying HDMI card profile '$PROFILE_NAME' now that direct ALSA stream is open..."
        if pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME" >/dev/null 2>&1; then
            echo "Re-applied card profile: $PROFILE_NAME"
        else
            echo "Warning: Failed to re-apply card profile '$PROFILE_NAME' after direct ALSA open."
        fi
        sleep 1
    fi

    # (IEC958 Non-Audio is now configured BEFORE aplay launch — see above)
elif [ "$PLAYBACK_MODE" = "stdout" ]; then
    # Legacy mode: pipe encoder stdout into pw-play.
    PRODUCER_CMD=("${APP_CMD[@]}" --target "" --stdout "${COMMON_ARGS[@]}")
    pw-play --version > /tmp/pw_play_version.log 2>&1
    echo "Using legacy stdout playback mode via pw-play."
    echo "Using pw-play device: '$APP_TARGET_NAME'"
    echo "pw-play version info logged to /tmp/pw_play_version.log"

    if [ "$SHOW_RUNTIME_LOGS" = "1" ]; then
        (
            "${PRODUCER_CMD[@]}" 2> >(tee /tmp/pw-ac3-live.log >&2) | \
            pw-play \
                --format s16 \
                --rate 48000 \
                --channels 2 \
                --latency 1000ms \
                --properties "target.object=$APP_TARGET_NAME,application.name=pw-ac3-live,node.name=pw-ac3-live-output,stream.is-live=true" \
                - \
                2>&1 | tee /tmp/pw-play.log
        ) &
    else
        (
            "${PRODUCER_CMD[@]}" 2>/tmp/pw-ac3-live.log | \
            pw-play \
                --format s16 \
                --rate 48000 \
                --channels 2 \
                --latency 1000ms \
                --properties "target.object=$APP_TARGET_NAME,application.name=pw-ac3-live,node.name=pw-ac3-live-output,stream.is-live=true" \
                - \
                > /tmp/pw-play.log 2>&1
        ) &
    fi
    APP_PID=$!
else
    # Native mode: let pw-ac3-live create and manage its PipeWire playback stream.
    NATIVE_CMD=("${APP_CMD[@]}" --target "$APP_TARGET_NAME" "${COMMON_ARGS[@]}")
    echo "Using native PipeWire playback mode (target: $APP_TARGET_NAME)."
    if [ "$SHOW_RUNTIME_LOGS" = "1" ]; then
        (
            "${NATIVE_CMD[@]}" 2>&1 | tee /tmp/pw-ac3-live.log
        ) &
    else
        "${NATIVE_CMD[@]}" > /tmp/pw-ac3-live.log 2>&1 &
    fi
    APP_PID=$!
fi

echo "Pipeline launched with PID $APP_PID (pw-ac3-live log: /tmp/pw-ac3-live.log)"
    
    # DEBUG: Check if process is running
    echo "DEBUG: Checking if PID $APP_PID is running..."
    if ps -p "$APP_PID" > /dev/null; then
        echo "DEBUG: Process $APP_PID is running."
    else
        echo "DEBUG: Process $APP_PID is NOT running immediately after launch!"
    fi

    # Update cleanup trap to debug
    trap 'run_cleanup_once "DEBUG: Trap triggered at $(date). Cleaning up..."; exit' INT TERM EXIT

    monitor_stats() {
        echo "Starting stats monitor..."
        while kill -0 "$APP_PID" 2>/dev/null; do
            # Monitor aplay delay if available
            if [ -n "$DIRECT_ALSA_HW_FALLBACK_DEVICE" ] || [ -n "$DIRECT_ALSA_APLAY_DEVICE" ]; then
                local dev="${DIRECT_ALSA_APLAY_DEVICE:-$DIRECT_ALSA_HW_FALLBACK_DEVICE}"
                local card="${dev#hw:}"
                card="${card%%,*}"
                local device="${dev##*,}"
                local status_file="/proc/asound/card${card}/pcm${device}p/sub0/status"
                if [ -f "$status_file" ]; then
                    local delay=$(grep "delay" "$status_file" | awk '{print $3}')
                    local avail=$(grep "avail" "$status_file" | awk '{print $3}')
                    if [ -n "$delay" ]; then
                        echo "STATS: aplay delay=${delay} frames ($((delay * 1000 / 48000)) ms) avail=${avail}"
                    fi
                fi
            fi
            
            # Monitor pw-ac3-live latency logs
            if [ -f "/tmp/pw-ac3-live.log" ]; then
                tail -n 20 /tmp/pw-ac3-live.log | grep "latency" | tail -n 1
            fi
            
            sleep 1
        done
    }

    # Launch stats monitor in background
    monitor_stats &

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
if [ "$USE_DIRECT_APLAY" != "1" ]; then
    echo "Ensuring encoder output is linked to HDMI..."
    PRIMARY_LINK_TARGET=""
    if pipewire_input_node_exists "$CONNECT_TARGET_PATTERN"; then
        PRIMARY_LINK_TARGET="$CONNECT_TARGET_PATTERN"
    elif pipewire_input_node_exists "$SINK_NAME"; then
        PRIMARY_LINK_TARGET="$SINK_NAME"
    fi
    
    if [ -z "$PRIMARY_LINK_TARGET" ]; then
        echo "Error: Could not find a valid playback node for linking."
        echo "Tried: CONNECT_TARGET='$CONNECT_TARGET_PATTERN' SINK_NAME='$SINK_NAME'"
        echo "Available input nodes:"
        pw-link -i | awk -F: '{print $1}' | sort -u
        exit 1
    fi
    
    echo "Using link target pattern: $PRIMARY_LINK_TARGET"
    CONNECT_RC=0
    "${SCRIPT_DIR}/connect.sh" "$PRIMARY_LINK_TARGET" || CONNECT_RC=$?
    if [ "$CONNECT_RC" -ne 0 ]; then
        if [ "$CONNECT_RC" -eq 13 ] && [ -n "$LOOPBACK_FALLBACK_TARGET" ] && [ "$PRIMARY_LINK_TARGET" != "$LOOPBACK_FALLBACK_TARGET" ] && pipewire_input_node_exists "$LOOPBACK_FALLBACK_TARGET"; then
            echo "Link policy denied target '$PRIMARY_LINK_TARGET'. Retrying with loopback target '$LOOPBACK_FALLBACK_TARGET'..."
            CONNECT_FALLBACK_RC=0
            "${SCRIPT_DIR}/connect.sh" "$LOOPBACK_FALLBACK_TARGET" || CONNECT_FALLBACK_RC=$?
            if [ "$CONNECT_FALLBACK_RC" -ne 0 ]; then
                echo "Error: Fallback link to '$LOOPBACK_FALLBACK_TARGET' failed (exit code $CONNECT_FALLBACK_RC)."
                exit "$CONNECT_FALLBACK_RC"
            fi
            PRIMARY_LINK_TARGET="$LOOPBACK_FALLBACK_TARGET"
        else
            echo "Error: Failed to link encoder output to '$PRIMARY_LINK_TARGET' (exit code $CONNECT_RC)."
            if [ "$CONNECT_RC" -eq 13 ]; then
                echo "Hint: PipeWire policy denied direct link creation for that target node."
                echo "Try without PW_AC3_APP_TARGET/PW_AC3_CONNECT_TARGET overrides."
            fi
            exit "$CONNECT_RC"
        fi
    fi
fi

# 9. Enforce bitstream-safe runtime levels after graph creation
normalize_pw_ac3_live_levels

if [ "$USE_DIRECT_APLAY" = "1" ] || [ "$PLAYBACK_MODE" = "stdout" ]; then
    check_graph_health ""
else
    check_graph_health "${PRIMARY_LINK_TARGET:-$APP_TARGET_NAME}"
fi

echo "========================================"
ALSA_CARD_INDEX_DIAG="${ALSA_CARD_INDEX_DIAG:-0}"
dump_audio_state "FINAL-LAUNCH-STATE" "$ALSA_CARD_INDEX_DIAG" "${EXPLICIT_ALSA_DEVICE:-}"
echo "LAUNCH SUCCESSFUL"
echo "pw-ac3-live is running. Press SINK VOLUME warning: Ensure your physical receiver volume is strictly controlled!"
echo "Main logs are above. Press Ctrl+C to stop everything."
echo "========================================"

# Wait for the app to finish (so the script doesn't exit and kill the background job if the shell closes?)
# If the user runs this from a click, they might not see stdout.
# But for a script, usually we wait.
# Wait for the app to finish
wait $APP_PID
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "Error: Pipeline exited with code $EXIT_CODE"
fi

if [ -f "/tmp/pacat.log" ]; then
    # Only print pacat log if it exists and has errors (optional)
    :
fi
if [ -f "/tmp/pw-play.log" ]; then
    echo "=== pw-play log (/tmp/pw-play.log) ==="
    cat "/tmp/pw-play.log"
    echo "=================================="
fi
if [ -f "/tmp/pw-ac3-live.log" ]; then
    echo "=== pw-ac3-live log (/tmp/pw-ac3-live.log) ==="
    cat "/tmp/pw-ac3-live.log"
    echo "=================================="
fi
# ALWAYS print aplay log for debugging
if [ -f "/tmp/aplay.log" ]; then
    echo "=== aplay log (/tmp/aplay.log) ==="
    cat "/tmp/aplay.log"
    echo "=================================="
fi

exit $EXIT_CODE
