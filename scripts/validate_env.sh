#!/bin/bash
# Environment Check for pw-ac3-live
#
# Non-destructive, read-only diagnostic of the system environment.
# Checks static/semi-static aspects: installed tools, sound cards,
# HDMI profiles, ALSA devices, ELD data from connected monitors.
#
# Usage: ./tests/scripts/validate_env.sh
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

header()  { echo -e "\n${BOLD}$1${NC}"; }
detail()  { echo -e "    ${DIM}$1${NC}"; }
check() {
    local label="$1" status="$2" msg="${3:-}"
    printf "  %-48s [%b]" "$label" "$status"
    [ -n "$msg" ] && printf "  %s" "$msg"
    echo ""
}

# Cache pactl output once
PACTL_CARDS=""
has_pactl() { command -v pactl >/dev/null 2>&1; }
if has_pactl; then
    PACTL_CARDS=$(pactl list cards 2>/dev/null || true)
fi

# ══════════════════════════════════════════════════════════════════════
header "═══ pw-ac3-live Environment Check ═══"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. Dependencies ───────────────────────────────────────────────────
header "Dependencies"

DEPS=(ffmpeg aplay iecset pactl pw-cli pw-link pw-play pw-cat pw-metadata wpctl)
for dep in "${DEPS[@]}"; do
    if command -v "$dep" >/dev/null 2>&1; then
        ver=""
        case "$dep" in
            ffmpeg)  ver=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}') ;;
            aplay)   ver=$(aplay --version 2>/dev/null | grep -oP '\d+\.\d+[\w.-]*' | head -1) ;;
            pw-cli)  ver=$(pw-cli --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true) ;;
        esac
        check "$dep" "$PASS" "${ver:+v$ver}"
    else
        case "$dep" in
            ffmpeg|pactl|pw-cli|pw-link)
                check "$dep" "$FAIL" "not found"
                FAILURES=$((FAILURES + 1)) ;;
            iecset|wpctl|pw-metadata|pw-cat)
                check "$dep" "$INFO" "not found (optional)" ;;
            *)
                check "$dep" "$WARN" "not found"
                WARNINGS=$((WARNINGS + 1)) ;;
        esac
    fi
done

# ── 2. PipeWire daemon ────────────────────────────────────────────────
header "PipeWire Daemon"

if pw-cli info 0 >/dev/null 2>&1; then
    PW_VERSION=$(pw-cli info 0 2>/dev/null | grep -oP 'version:\s*"\K[^"]+' || echo "unknown")
    check "PipeWire daemon running" "$PASS" "v${PW_VERSION}"
else
    check "PipeWire daemon running" "$FAIL" ""
    FAILURES=$((FAILURES + 1))
fi

# ── 3. HDMI Cards & Profiles ─────────────────────────────────────────
header "HDMI Cards & Profiles"

if has_pactl; then
    CARDS_SHORT=$(pactl list cards short 2>/dev/null || true)
    if [ -n "$CARDS_SHORT" ]; then
        while IFS=$'\t' read -r card_idx card_name _rest; do
            [ -z "$card_name" ] && continue
            ACTIVE_PROFILE=$(echo "$PACTL_CARDS" | awk -v c="$card_name" '
                $1=="Name:" && $2==c { found=1; next }
                found && $1=="Active" && $2=="Profile:" { print $3; exit }
                found && $1=="Name:" && $2!=c { exit }
            ')

            HAS_HDMI=$(echo "$PACTL_CARDS" | awk -v c="$card_name" '
                $1=="Name:" && $2==c { found=1; next }
                found && /output:hdmi/ { print "yes"; exit }
                found && $1=="Name:" && $2!=c { exit }
            ')

            if [ "$HAS_HDMI" = "yes" ]; then
                HDMI_STEREO=$(echo "$PACTL_CARDS" | awk -v c="$card_name" '
                    $1=="Name:" && $2==c { found=1; next }
                    found && /output:hdmi-stereo/ && !/surround/ && /available: yes/ { gsub(/:$/,"",$1); print $1; }
                    found && $1=="Name:" && $2!=c { exit }
                ')
                if [ -n "$HDMI_STEREO" ]; then
                    check "Card: $card_name" "$PASS" "active profile: ${ACTIVE_PROFILE:-?}"
                else
                    check "Card: $card_name" "$INFO" "active profile: ${ACTIVE_PROFILE:-?}  (no usable hdmi-stereo)"
                fi

                echo "$PACTL_CARDS" | awk -v c="$card_name" '
                    $1=="Name:" && $2==c { found=1; next }
                    found && /^[[:space:]]+output:hdmi/ && !/Part of/ {
                        line=$0; gsub(/^[[:space:]]+/,"",line)
                        if (match(line, /: [A-Z]/)) {
                            pname = substr(line, 1, RSTART-1)
                        } else {
                            pname = $1; gsub(/:$/,"",pname)
                        }
                        avail=""
                        if (match($0, /available: (yes|no)/, m)) avail=m[1]
                        printf "    %-55s %s\n", pname, avail
                    }
                    found && $1=="Name:" && $2!=c { exit }
                '
            fi
        done <<< "$CARDS_SHORT"
    fi
fi

# ── 4. ALSA Hardware ─────────────────────────────────────────────────
header "ALSA Hardware"

if [ -d "/proc/asound" ]; then
    for card_dir in /proc/asound/card*/; do
        [ -d "$card_dir" ] || continue
        card_num=$(basename "$card_dir" | sed 's/card//')
        card_id=$(cat "$card_dir/id" 2>/dev/null || echo "?")

        for pcm_file in "$card_dir"pcm*p/sub0/status; do
            [ -f "$pcm_file" ] || continue
            pcm_name=$(echo "$pcm_file" | grep -oP 'pcm\d+')
            dev_num=$(echo "$pcm_name" | grep -oP '\d+')
            state=$(head -1 "$pcm_file" 2>/dev/null | awk '{print $2}')

            if [ "$dev_num" -ge 3 ] 2>/dev/null || [ "$state" = "RUNNING" ]; then
                if [ "$state" = "RUNNING" ]; then
                    hw_info=$(cat "$pcm_file" 2>/dev/null | head -5 | grep -E "rate|format" | tr '\n' ', ' | sed 's/,$//')
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

# ── 5. ELD (EDID-Like Data) ──────────────────────────────────────────
header "ELD — Connected Monitors / Receivers"

HAS_ELD=0
if [ -d "/proc/asound" ]; then
    for eld_file in /proc/asound/card*/eld*; do
        [ -f "$eld_file" ] || continue
        mon_present=$(awk '/^monitor_present/ { print $2 }' "$eld_file")
        [ "$mon_present" != "1" ] && continue

        HAS_ELD=1
        eld_name=$(basename "$eld_file")
        card_dir=$(dirname "$eld_file")
        card_num=$(basename "$card_dir" | sed 's/card//')
        card_id=$(cat "$card_dir/id" 2>/dev/null || echo "?")

        mon_name=$(awk '/^monitor_name/ { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")
        conn_type=$(awk '/^connection_type/ { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")
        speakers=$(awk '/^speakers/ { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")
        sad_count=$(awk '/^sad_count/ { print $2 }' "$eld_file")

        check "card${card_num} ${eld_name}: ${mon_name:-?}" "$INFO" "${conn_type:-?}"
        detail "speakers: ${speakers:-?}"

        # Parse SAD entries
        MAX_PCM_CH=0
        MAX_AC3_CH=0
        if [ "${sad_count:-0}" -gt 0 ]; then
            for i in $(seq 0 $((sad_count - 1))); do
                codec=$(awk -v n="$i" '$1=="sad"n"_coding_type" { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")
                channels=$(awk -v n="$i" '$1=="sad"n"_channels" { print $2 }' "$eld_file")
                rates=$(awk -v n="$i" '$1=="sad"n"_rates" { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")
                bits=$(awk -v n="$i" '$1=="sad"n"_bits" { $1=""; gsub(/^[[:space:]]+/,""); print }' "$eld_file")

                codec_short=$(echo "$codec" | grep -oP '\] \K.*' || echo "$codec")
                extra="${channels:+${channels}ch} ${rates:-}"
                [ -n "$bits" ] && extra="${extra}, bits: $bits"

                detail "sad${i}: ${codec_short:-?} (${extra})"

                ch_num="${channels:-0}"
                if echo "$codec" | grep -qi "LPCM\|PCM"; then
                    [ "$ch_num" -gt "$MAX_PCM_CH" ] && MAX_PCM_CH="$ch_num"
                fi
                if echo "$codec" | grep -qi "AC-3\|AC3"; then
                    [ "$ch_num" -gt "$MAX_AC3_CH" ] && MAX_AC3_CH="$ch_num"
                fi
            done

            # Surround capability summary
            PCM_51="no"; PCM_71="no"; AC3_51="no"; AC3_71="no"
            [ "$MAX_PCM_CH" -ge 6 ] && PCM_51="yes"
            [ "$MAX_PCM_CH" -ge 8 ] && PCM_71="yes"
            [ "$MAX_AC3_CH" -ge 6 ] && AC3_51="yes"
            [ "$MAX_AC3_CH" -ge 8 ] && AC3_71="yes"

            if [ "$PCM_51" = "yes" ] && [ "$PCM_71" = "yes" ]; then
                check "  PCM surround (${mon_name:-?})" "$PASS" "5.1 ✓  7.1 ✓  (max ${MAX_PCM_CH}ch)"
            elif [ "$PCM_51" = "yes" ]; then
                check "  PCM surround (${mon_name:-?})" "$PASS" "5.1 ✓  7.1 ✗  (max ${MAX_PCM_CH}ch)"
            else
                check "  PCM surround (${mon_name:-?})" "$INFO" "stereo only (max ${MAX_PCM_CH}ch)"
            fi

            if [ "$MAX_AC3_CH" -gt 0 ]; then
                if [ "$AC3_51" = "yes" ] && [ "$AC3_71" = "yes" ]; then
                    check "  AC-3 surround (${mon_name:-?})" "$PASS" "5.1 ✓  7.1 ✓  (max ${MAX_AC3_CH}ch)"
                elif [ "$AC3_51" = "yes" ]; then
                    check "  AC-3 surround (${mon_name:-?})" "$PASS" "5.1 ✓  7.1 ✗  (max ${MAX_AC3_CH}ch)"
                else
                    check "  AC-3 surround (${mon_name:-?})" "$INFO" "AC-3 ${MAX_AC3_CH}ch only"
                fi
            else
                check "  AC-3 support (${mon_name:-?})" "$WARN" "no AC-3 SAD — monitor/display only?"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            detail "no audio descriptors (sad_count=0)"
        fi
    done
fi

if [ "$HAS_ELD" -eq 0 ]; then
    check "ELD data" "$INFO" "no monitors connected via HDMI/DP"
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
