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

# Keep fixed-width tables readable when names are very long.
shorten() {
    local text="$1" max_len="$2"
    if [ "${#text}" -le "$max_len" ]; then
        printf "%s" "$text"
    else
        printf "%s..." "${text:0:$((max_len - 3))}"
    fi
}

get_card_active_profile() {
    local card_name="$1"
    echo "$PACTL_CARDS" | awk -v c="$card_name" '
        $1=="Name:" && $2==c { found=1; next }
        found && $1=="Active" && $2=="Profile:" {
            $1=""
            $2=""
            sub(/^[[:space:]]+/, "", $0)
            print $0
            exit
        }
        found && $1=="Name:" && $2!=c { exit }
    '
}

get_sink_card_and_profile() {
    local sink_name="$1"
    echo "$PACTL_SINKS" | awk -v s="$sink_name" '
        /^Sink #[0-9]+/ {
            if (in_sink) exit
            in_sink=0
        }
        /^[[:space:]]+Name:/ {
            if ($2 == s) {
                in_sink=1
            } else if (in_sink) {
                exit
            }
            next
        }
        in_sink && /alsa.card_name =/ && card=="" {
            if (match($0, /"[^"]+"/)) card=substr($0, RSTART+1, RLENGTH-2)
        }
        in_sink && /device.profile.name =/ && profile=="" {
            if (match($0, /"[^"]+"/)) profile=substr($0, RSTART+1, RLENGTH-2)
        }
        END {
            if (card=="") card="?"
            if (profile=="") profile="?"
            print card "\t" profile
        }
    '
}

# Cache pactl output once
PACTL_CARDS=""
PACTL_SINKS=""
has_pactl() { command -v pactl >/dev/null 2>&1; }
if has_pactl; then
    PACTL_CARDS=$(pactl list cards 2>/dev/null || true)
    PACTL_SINKS=$(pactl list sinks 2>/dev/null || true)
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

# ── 3. PipeWire Cards & Profiles ─────────────────────────────────────
header "PipeWire Cards & Profiles"

if has_pactl; then
    CARDS_SHORT=$(pactl list cards short 2>/dev/null || true)
    if [ -z "$CARDS_SHORT" ]; then
        check "PipeWire cards" "$WARN" "none found via pactl"
        WARNINGS=$((WARNINGS + 1))
    else
        detail "* marks the active profile"
        while IFS=$'\t' read -r card_idx card_name _rest; do
            [ -z "$card_name" ] && continue
            ACTIVE_PROFILE=$(get_card_active_profile "$card_name")

            check "Card #${card_idx}: ${card_name}" "$INFO" "active profile: ${ACTIVE_PROFILE:-?}"

            PROFILE_LINES=$(echo "$PACTL_CARDS" | awk -v c="$card_name" -v active="$ACTIVE_PROFILE" '
                BEGIN { in_card=0; in_profiles=0; found=0; active_marked=0 }
                $1=="Name:" { in_card=($2==c); in_profiles=0; next }
                in_card && $1=="Profiles:" { in_profiles=1; next }
                in_card && $1=="Active" && $2=="Profile:" { exit }
                in_card && in_profiles {
                    if ($0 !~ /^[[:space:]]+/) next
                    line=$0
                    gsub(/^[[:space:]]+/, "", line)

                    sep=index(line, ": ")
                    if (sep > 0) {
                        pname=substr(line, 1, sep-1)
                        details=substr(line, sep+2)
                    } else {
                        pname=line
                        details=""
                    }
                    if (pname=="") next

                    avail="unknown"
                    if (match(line, /available: (yes|no|unknown)/, m)) avail=m[1]
                    status=(avail=="yes" ? "ready" : (avail=="no" ? "not-ready" : "unknown"))

                    # Render availability as a readable status; keep the rest as context.
                    sub(/[[:space:]]*,?[[:space:]]*available: (yes|no|unknown)/, "", details)
                    gsub(/[[:space:]]+$/, "", details)

                    seen[pname]++
                    display_name=pname
                    if (seen[pname] > 1) {
                        display_name=pname " #" seen[pname]
                    }

                    if (pname==active && active_marked==0) {
                        marker="*"
                        active_marked=1
                    } else {
                        marker=" "
                    }
                    printf "    %s %-40s %-10s %s\n", marker, display_name, status, details
                    found=1
                }
                END {
                    if (!found) print "    (no profiles reported)"
                }
            ')
            echo "$PROFILE_LINES"
        done <<< "$CARDS_SHORT"
    fi
else
    check "pactl cards listing" "$SKIP" "pactl not available"
fi

# ── 4. PipeWire Objects Tables ───────────────────────────────────────
header "PipeWire Objects Tables"

if has_pactl; then
    CARDS_SHORT=$(pactl list cards short 2>/dev/null || true)
    SINKS_SHORT=$(pactl list sinks short 2>/dev/null || true)

    detail "Card objects (from \`pactl list cards short\`)"
    printf "    %-5s %-50s %-18s %-28s\n" "idx" "card.object" "driver" "active-profile"
    printf "    %-5s %-50s %-18s %-28s\n" "---" "-----------" "------" "--------------"
    if [ -n "$CARDS_SHORT" ]; then
        while IFS=$'\t' read -r card_idx card_name card_driver _rest; do
            [ -z "$card_name" ] && continue
            active_profile=$(get_card_active_profile "$card_name")
            card_name_show=$(shorten "$card_name" 50)
            card_driver_show=$(shorten "${card_driver:-?}" 18)
            active_profile_show=$(shorten "${active_profile:-?}" 28)
            printf "    %-5s %-50s %-18s %-28s\n" "$card_idx" "$card_name_show" "$card_driver_show" "$active_profile_show"
        done <<< "$CARDS_SHORT"
    else
        echo "    (no cards found)"
    fi

    detail "Sink node names (from \`pactl list sinks short\`)"
    printf "    %-5s %-50s %-10s %-7s %-24s %-22s\n" "idx" "sink.node.name" "state" "ch" "alsa.card_name" "profile"
    printf "    %-5s %-50s %-10s %-7s %-24s %-22s\n" "---" "--------------" "-----" "--" "--------------" "-------"
    if [ -n "$SINKS_SHORT" ]; then
        while IFS=$'\t' read -r sink_idx sink_name sink_driver sink_spec sink_state _rest; do
            [ -z "$sink_name" ] && continue
            channel_count=$(echo "$sink_spec" | grep -oE '[0-9]+ch' | head -1 || true)
            [ -z "$channel_count" ] && channel_count="?"
            IFS=$'\t' read -r sink_card_name sink_profile_name <<< "$(get_sink_card_and_profile "$sink_name")"
            sink_name_show=$(shorten "$sink_name" 50)
            sink_state_show=$(shorten "${sink_state:-?}" 10)
            sink_card_show=$(shorten "${sink_card_name:-?}" 24)
            sink_profile_show=$(shorten "${sink_profile_name:-?}" 22)
            printf "    %-5s %-50s %-10s %-7s %-24s %-22s\n" \
                "$sink_idx" "$sink_name_show" "$sink_state_show" "$channel_count" "$sink_card_show" "$sink_profile_show"
        done <<< "$SINKS_SHORT"
    else
        echo "    (no sinks found)"
    fi
else
    check "PipeWire objects table" "$SKIP" "pactl not available"
fi

# ── 5. ALSA Hardware ─────────────────────────────────────────────────
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
            status_line=$(head -1 "$pcm_file" 2>/dev/null || true)
            state=$(echo "$status_line" | awk '{print $2}')
            [ -z "$state" ] && state=$(echo "$status_line" | awk '{print toupper($1)}')
            [ -z "$state" ] && state="CLOSED"

            info_file="${card_dir}${pcm_name}p/info"
            pcm_id=$(awk -F ': ' '/^id:/ { print $2; exit }' "$info_file" 2>/dev/null || true)
            [ -z "$pcm_id" ] && pcm_id="$pcm_name"

            if echo "$pcm_id" | grep -qi 'HDMI'; then
                endpoint_kind="HDMI"
            else
                endpoint_kind="non-HDMI"
            fi

            case "$state" in
                RUNNING)
                    check_state="$PASS"
                    state_label="in use (streaming)"
                    ;;
                PREPARED)
                    check_state="$INFO"
                    state_label="opened (ready)"
                    ;;
                XRUN)
                    check_state="$WARN"
                    state_label="xrun (underrun/overrun)"
                    WARNINGS=$((WARNINGS + 1))
                    ;;
                DRAINING)
                    check_state="$INFO"
                    state_label="draining"
                    ;;
                SUSPENDED)
                    check_state="$INFO"
                    state_label="suspended"
                    ;;
                *)
                    check_state="$INFO"
                    state_label="idle (free)"
                    ;;
            esac

            if [ "$dev_num" -ge 3 ] 2>/dev/null || [ "$state" = "RUNNING" ] || [ "$state" = "PREPARED" ]; then
                if [ "$state" = "RUNNING" ]; then
                    hw_info=$(head -5 "$pcm_file" 2>/dev/null | grep -E "rate|format" | tr '\n' ', ' | sed 's/,$//')
                    check "hw:${card_num},${dev_num} (${card_id}/${pcm_id})" "$check_state" "${endpoint_kind}, ${state_label}${hw_info:+ [$hw_info]}"
                else
                    check "hw:${card_num},${dev_num} (${card_id}/${pcm_id})" "$check_state" "${endpoint_kind}, ${state_label}"
                fi
            fi
        done
    done
else
    check "ALSA /proc/asound" "$SKIP" "not available"
fi

# ── 6. ELD (EDID-Like Data) ──────────────────────────────────────────
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
