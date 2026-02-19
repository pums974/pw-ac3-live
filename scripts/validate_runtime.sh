#!/bin/bash
# Runtime Check for pw-ac3-live
#
# Non-destructive, read-only diagnostic of the live audio pipeline.
# Checks runtime state: processes, PipeWire graph, sinks, streams,
# IEC958 status — all things that launch_live_* scripts change.
#
# Usage: ./tests/scripts/validate_runtime.sh
#
# Exit 0 = all critical checks pass
# Exit 1 = one or more FAIL
set -uo pipefail

# ── Colors ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}PASS${NC}"
FAIL="${RED}FAIL${NC}"
WARN="${YELLOW}WARN${NC}"
INFO="${CYAN}INFO${NC}"
SKIP="${CYAN}SKIP${NC}"

FAILURES=0
WARNINGS=0

header() { echo -e "\n${BOLD}$1${NC}"; }
detail() { echo -e "    ${DIM}$1${NC}"; }
check() {
  local label="$1" status="$2" msg="${3:-}"
  printf "  %-48s [%b]" "$label" "$status"
  [ -n "$msg" ] && printf "  %s" "$msg"
  echo ""
}

# Cache pactl output once (expensive to call repeatedly)
PACTL_SINKS=""
PACTL_SINK_INPUTS=""
has_pactl() { command -v pactl > /dev/null 2>&1; }
cache_pactl() {
  if has_pactl; then
    PACTL_SINKS=$(pactl list sinks 2> /dev/null || true)
    PACTL_SINK_INPUTS=$(pactl list sink-inputs 2> /dev/null || true)
  fi
}
cache_pactl

# ══════════════════════════════════════════════════════════════════════
header "═══ pw-ac3-live Runtime Check ═══"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. PipeWire Daemon (graph settings) ──────────────────────────────
header "PipeWire Daemon"

if pw-cli info 0 > /dev/null 2>&1; then
  PW_VERSION=$(pw-cli info 0 2> /dev/null | grep -oP 'version:\s*"\K[^"]+' || echo "unknown")
  check "PipeWire daemon running" "$PASS" "v${PW_VERSION}"
else
  check "PipeWire daemon running" "$FAIL" ""
  FAILURES=$((FAILURES + 1))
fi

# Graph quantum/rate (launch scripts can force these)
if command -v pw-metadata > /dev/null 2>&1; then
  PW_META=$(pw-metadata -n settings 2> /dev/null || true)
  QUANTUM=$(echo "$PW_META" | grep "clock.force-quantum" | grep -oP "value:'\K[^']+" || true)
  RATE=$(echo "$PW_META" | grep "clock.force-rate" | grep -oP "value:'\K[^']+" || true)
  DEFAULT_QUANTUM=$(echo "$PW_META" | grep "clock.quantum" | grep -v "force\|min\|max" | grep -oP "value:'\K[^']+" || true)
  DEFAULT_RATE=$(echo "$PW_META" | grep "clock.rate" | grep -v "force\|allowed" | grep -oP "value:'\K[^']+" || true)
  if [ -n "$QUANTUM" ] && [ "$QUANTUM" != "0" ]; then
    check "Graph quantum (forced)" "$INFO" "${QUANTUM} frames"
  elif [ -n "$DEFAULT_QUANTUM" ]; then
    check "Graph quantum (default)" "$INFO" "${DEFAULT_QUANTUM} frames"
  fi
  if [ -n "$RATE" ] && [ "$RATE" != "0" ]; then
    check "Graph rate (forced)" "$INFO" "${RATE} Hz"
  elif [ -n "$DEFAULT_RATE" ]; then
    check "Graph rate (default)" "$INFO" "${DEFAULT_RATE} Hz"
  fi
fi

# ── 2. Processes ──────────────────────────────────────────────────────
header "Processes"

PW_AC3_PIDS=$(pgrep -x "pw-ac3-live" 2> /dev/null | head -5 || true)
if [ -n "$PW_AC3_PIDS" ]; then
  check "pw-ac3-live process" "$PASS" "PID(s): $(echo $PW_AC3_PIDS | tr '\n' ' ')"
else
  check "pw-ac3-live process" "$WARN" "not running"
  WARNINGS=$((WARNINGS + 1))
fi

FFMPEG_PIDS=$(pgrep -f "ffmpeg.*ac3" 2> /dev/null | head -5 || true)
if [ -n "$FFMPEG_PIDS" ]; then
  check "FFmpeg encoder subprocess" "$PASS" "PID(s): $(echo $FFMPEG_PIDS | tr '\n' ' ')"
elif [ -n "$PW_AC3_PIDS" ]; then
  check "FFmpeg encoder subprocess" "$WARN" "not found"
  WARNINGS=$((WARNINGS + 1))
else
  check "FFmpeg encoder subprocess" "$INFO" "not running"
fi

APLAY_PIDS=$(pgrep -f "aplay.*S16_LE" 2> /dev/null | head -5 || true)
if [ -n "$APLAY_PIDS" ]; then
  check "Direct ALSA aplay process" "$PASS" "PID(s): $(echo $APLAY_PIDS | tr '\n' ' ')"
else
  check "Direct ALSA aplay process" "$INFO" "not running"
fi

# ── 3. PipeWire graph ────────────────────────────────────────────────
header "PipeWire Graph"

if command -v pw-link > /dev/null 2>&1; then
  INPUT_PORTS=$(pw-link -i 2> /dev/null | grep "pw-ac3-live-input" | wc -l)
  if [ "$INPUT_PORTS" -gt 0 ]; then
    check "pw-ac3-live-input node" "$PASS" "${INPUT_PORTS} port(s)"
  elif [ -n "$PW_AC3_PIDS" ]; then
    check "pw-ac3-live-input node" "$WARN" "not found"
    WARNINGS=$((WARNINGS + 1))
  else
    check "pw-ac3-live-input node" "$INFO" "not present"
  fi

  OUTPUT_PORTS=$(pw-link -o 2> /dev/null | grep "pw-ac3-live-output" | wc -l)
  if [ "$OUTPUT_PORTS" -gt 0 ]; then
    check "pw-ac3-live-output node" "$PASS" "${OUTPUT_PORTS} port(s)"
  elif [ -n "$PW_AC3_PIDS" ]; then
    check "pw-ac3-live-output node" "$INFO" "not present (--stdout or direct ALSA)"
  else
    check "pw-ac3-live-output node" "$INFO" "not present"
  fi

  # Links into pw-ac3-live-input
  PW_LINKS=$(pw-link -l 2> /dev/null || true)
  INPUT_LINKS=$(echo "$PW_LINKS" | grep "pw-ac3-live-input" | grep -c "<-\|->" || true)
  if [ "$INPUT_LINKS" -gt 0 ]; then
    check "Links → pw-ac3-live-input" "$PASS" "${INPUT_LINKS} link(s)"
  elif [ "$INPUT_PORTS" -gt 0 ]; then
    check "Links → pw-ac3-live-input" "$WARN" "0 links (encoder input is silent)"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Links from pw-ac3-live-output
  if [ "$OUTPUT_PORTS" -gt 0 ]; then
    OUTPUT_LINKS=$(echo "$PW_LINKS" | grep "pw-ac3-live-output" | grep -c "<-\|->" || true)
    OUTPUT_TARGETS=$(echo "$PW_LINKS" | awk '/pw-ac3-live-output.*->/{
            split($0, a, "-> "); if (length(a)>=2) { split(a[2],b,":"); print b[1]; }
        }' | sort -u | tr '\n' ', ' | sed 's/,$//')
    if [ "$OUTPUT_LINKS" -gt 0 ]; then
      check "Links from pw-ac3-live-output" "$PASS" "${OUTPUT_LINKS} → ${OUTPUT_TARGETS:-?}"
    else
      check "Links from pw-ac3-live-output" "$WARN" "0 links (output disconnected)"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# ── 4. Sinks ─────────────────────────────────────────────────────────
header "Sinks"

if has_pactl; then
  DEFAULT_SINK=$(pactl get-default-sink 2> /dev/null || echo "")
  SINKS_SHORT=$(pactl list sinks short 2> /dev/null || true)

  # Default sink
  if [ "$DEFAULT_SINK" = "pw-ac3-live-input" ]; then
    check "Default sink" "$PASS" "pw-ac3-live-input"
  elif [ -n "$DEFAULT_SINK" ]; then
    check "Default sink" "$INFO" "${DEFAULT_SINK}"
  else
    check "Default sink" "$WARN" "could not determine"
  fi

  # HDMI sinks: match by name or description containing 'hdmi'
  HDMI_SINKS=$(echo "$PACTL_SINKS" | awk '
        /^\tName:/ { name=$2 }
        /Description:.*[Hh][Dd][Mm][Ii]/ { print name }
    ' | sort -u)
  HDMI_SINKS_BY_NAME=$(echo "$SINKS_SHORT" | awk '$2 ~ /hdmi/ { print $2 }')
  HDMI_SINKS=$(echo -e "${HDMI_SINKS}\n${HDMI_SINKS_BY_NAME}" | grep -v '^$' | sort -u)
  LOOPBACK_SINKS=$(echo "$SINKS_SHORT" | awk '$2 ~ /loopback/ { print $2 }')

  if [ -z "$HDMI_SINKS" ] && [ -z "$LOOPBACK_SINKS" ]; then
    check "HDMI sinks" "$WARN" "none found"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Process each interesting sink
  ALL_INTERESTING=$(echo -e "${HDMI_SINKS}\n${LOOPBACK_SINKS}" | grep -v '^$' | sort -u)
  if echo "$SINKS_SHORT" | grep -q "pw-ac3-live-input"; then
    ALL_INTERESTING=$(echo -e "pw-ac3-live-input\n${ALL_INTERESTING}")
  fi

  while IFS= read -r sink_name; do
    [ -z "$sink_name" ] && continue

    SINK_VOL=$(echo "$PACTL_SINKS" | awk -v s="$sink_name" '
            $1=="Name:" && $2==s { found=1; next }
            found && /^\tVolume:/ { gsub(/.*\/\s*/,""); gsub(/\s*\/.*$/,""); print; found=0 }
            found && $1=="Name:" && $2!=s { found=0 }
        ' | head -1)

    SINK_MUTE=$(echo "$PACTL_SINKS" | awk -v s="$sink_name" '
            $1=="Name:" && $2==s { found=1; next }
            found && /Mute:/ { print $2; found=0 }
            found && $1=="Name:" && $2!=s { found=0 }
        ' | head -1)

    SINK_STATE=$(echo "$SINKS_SHORT" | awk -v s="$sink_name" '$2==s { print $NF }')

    HAS_AC3=$(echo "$PACTL_SINKS" | awk -v s="$sink_name" '
            $1=="Name:" && $2==s { found=1; next }
            found && /ac3-iec61937/ { print "yes"; found=0 }
            found && $1=="Name:" && $2!=s { found=0 }
        ')

    LABEL="$sink_name"
    if [[ "$sink_name" == *loopback* ]]; then
      LABEL="$sink_name (loopback)"
    elif [[ "$sink_name" == pw-ac3-live-input ]]; then
      LABEL="$sink_name (encoder)"
    fi

    VOL_STATUS="$PASS"
    if [ "$SINK_MUTE" = "yes" ]; then
      VOL_STATUS="$WARN"
      WARNINGS=$((WARNINGS + 1))
    fi

    VOL_DETAIL="${SINK_VOL:-?}"
    [ "$SINK_MUTE" = "yes" ] && VOL_DETAIL="${VOL_DETAIL} MUTED!"
    [ -n "$SINK_STATE" ] && VOL_DETAIL="${VOL_DETAIL}, state=${SINK_STATE}"
    [ "$HAS_AC3" = "yes" ] && VOL_DETAIL="${VOL_DETAIL}, ac3=yes"

    check "$LABEL" "$VOL_STATUS" "$VOL_DETAIL"

    # Sink format details
    FORMATS=$(echo "$PACTL_SINKS" | awk -v s="$sink_name" '
            $1=="Name:" && $2==s { found=1; next }
            found && /Formats:/ { in_fmt=1; next }
            found && in_fmt && /^\t\t/ { gsub(/^\t+/,""); print; next }
            found && in_fmt && !/^\t\t/ { in_fmt=0 }
            found && $1=="Name:" && $2!=s { found=0; in_fmt=0 }
        ')
    if [ -n "$FORMATS" ]; then
      echo "$FORMATS" | while IFS= read -r fmt_line; do
        [ -n "$fmt_line" ] && detail "format: $fmt_line"
      done
    fi
  done <<< "$ALL_INTERESTING"

  # Loopback presence summary
  LOOPBACK_COUNT=$(echo "$LOOPBACK_SINKS" | grep -c '.' || true)
  if [ "$LOOPBACK_COUNT" -gt 0 ]; then
    check "Loopback sink(s) detected" "$INFO" "${LOOPBACK_COUNT} loopback(s)"
  else
    check "Loopback sinks" "$INFO" "none detected"
  fi
fi

# ── 5. Streams → Sinks ───────────────────────────────────────────────
header "Streams → Sinks"

if has_pactl; then
  STREAM_COUNT=0
  SINKS_SHORT_DATA=$(pactl list sinks short 2> /dev/null || true)

  CURRENT_ID=""
  CURRENT_SINK_IDX=""
  CURRENT_APP=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^"Sink Input #"([0-9]+) ]]; then
      if [ -n "$CURRENT_ID" ] && [ -n "$CURRENT_APP" ]; then
        SINK_NAME_FOR_STREAM=$(echo "$SINKS_SHORT_DATA" | awk -v idx="$CURRENT_SINK_IDX" '$1==idx { print $2; exit }')
        check "#${CURRENT_ID}: ${CURRENT_APP}" "$INFO" "→ ${SINK_NAME_FOR_STREAM:-sink#$CURRENT_SINK_IDX}"
        STREAM_COUNT=$((STREAM_COUNT + 1))
      fi
      CURRENT_ID="${BASH_REMATCH[1]}"
      CURRENT_SINK_IDX=""
      CURRENT_APP=""
    elif [[ "$line" =~ Sink:\ ([0-9]+) ]]; then
      CURRENT_SINK_IDX="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ application\.name\ =\ \"(.+)\" ]]; then
      CURRENT_APP="${BASH_REMATCH[1]}"
    fi
  done <<< "$PACTL_SINK_INPUTS"

  # Last entry
  if [ -n "$CURRENT_ID" ] && [ -n "$CURRENT_APP" ]; then
    SINK_NAME_FOR_STREAM=$(echo "$SINKS_SHORT_DATA" | awk -v idx="$CURRENT_SINK_IDX" '$1==idx { print $2; exit }')
    check "#${CURRENT_ID}: ${CURRENT_APP}" "$INFO" "→ ${SINK_NAME_FOR_STREAM:-sink#$CURRENT_SINK_IDX}"
    STREAM_COUNT=$((STREAM_COUNT + 1))
  fi

  if [ "$STREAM_COUNT" -eq 0 ]; then
    check "Active streams" "$INFO" "none"
  fi
fi

# ── 6. ALSA Hardware (runtime state) ─────────────────────────────────
header "ALSA Hardware"

if [ -d "/proc/asound" ]; then
  for card_dir in /proc/asound/card*/; do
    [ -d "$card_dir" ] || continue
    card_num=$(basename "$card_dir" | sed 's/card//')
    card_id=$(cat "$card_dir/id" 2> /dev/null || echo "?")

    for pcm_file in "$card_dir"pcm*p/sub0/status; do
      [ -f "$pcm_file" ] || continue
      pcm_name=$(echo "$pcm_file" | grep -oP 'pcm\d+')
      dev_num=$(echo "$pcm_name" | grep -oP '\d+')
      state=$(head -1 "$pcm_file" 2> /dev/null | awk '{print $2}')

      if [ "$dev_num" -ge 3 ] 2> /dev/null || [ "$state" = "RUNNING" ]; then
        if [ "$state" = "RUNNING" ]; then
          hw_info=$(cat "$pcm_file" 2> /dev/null | head -5 | grep -E "rate|format" | tr '\n' ', ' | sed 's/,$//')
          check "hw:${card_num},${dev_num} (${card_id})" "$PASS" "RUNNING ${hw_info:+[$hw_info]}"
        elif [ "$state" = "PREPARED" ]; then
          check "hw:${card_num},${dev_num} (${card_id})" "$INFO" "PREPARED"
        else
          check "hw:${card_num},${dev_num} (${card_id})" "$INFO" "${state:-closed}"
        fi
      fi
    done
  done
else
  check "ALSA /proc/asound" "$SKIP" "not available"
fi

# ── 7. IEC958 / S/PDIF ──────────────────────────────────────────────
header "IEC958 / S/PDIF"

if command -v iecset > /dev/null 2>&1; then
  for card_dir in /proc/asound/card*/; do
    [ -d "$card_dir" ] || continue
    card_num=$(basename "$card_dir" | sed 's/card//')
    card_id=$(cat "$card_dir/id" 2> /dev/null || echo "?")

    for idx in 0 1 2 3; do
      IEC_OUTPUT=$(iecset -c "$card_num" -n "$idx" 2> /dev/null || true)
      [ -z "$IEC_OUTPUT" ] && continue

      DATA_MODE=$(echo "$IEC_OUTPUT" | awk '/^Data:/ { print $2 }')
      IEC_RATE=$(echo "$IEC_OUTPUT" | awk '/^Rate:/ { $1=""; gsub(/^[[:space:]]+/,""); print }')

      if [ -n "$DATA_MODE" ]; then
        LABEL="card${card_num} (${card_id}) idx=${idx}"
        if [ "$DATA_MODE" = "non-audio" ]; then
          check "$LABEL" "$PASS" "non-audio (AC-3 passthrough), rate=${IEC_RATE:-?}"
        else
          check "$LABEL" "$INFO" "audio (PCM), rate=${IEC_RATE:-?}"
        fi
      fi
    done
  done
else
  check "iecset" "$SKIP" "not installed (apt: alsa-utils)"
fi

# ── Summary ───────────────────────────────────────────────────────────
header "═══ Summary ═══"
if [ "$FAILURES" -gt 0 ]; then
  echo -e "  ${RED}${BOLD}${FAILURES} FAILURE(s)${NC}, ${WARNINGS} warning(s)"
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo -e "  ${YELLOW}${BOLD}${WARNINGS} WARNING(s)${NC}, 0 failures"
  exit 0
else
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}"
  exit 0
fi
