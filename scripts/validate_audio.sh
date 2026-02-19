#!/bin/bash
# Interactive Audio Validation for pw-ac3-live
#
# Plays test tones through the running pw-ac3-live pipeline and
# prompts you to verify what you hear.
#
# Requirements:
#   - pw-ac3-live must be running (native PipeWire or direct ALSA mode)
#   - pw-ac3-live-input node must be visible in PipeWire graph
#   - ffmpeg and pw-play available
#
# Usage: 
#   ./tests/scripts/validate_audio.sh           # Run all tests
#   ./tests/scripts/validate_audio.sh 1         # Run Test 1 only
#   ./tests/scripts/validate_audio.sh 1 3       # Run Test 1 and 3
set -uo pipefail

RUN_TESTS=("1" "2" "3")
if [ $# -gt 0 ]; then
    RUN_TESTS=("$@")
fi

should_run() {
    local t="$1"
    for rt in "${RUN_TESTS[@]}"; do
        if [ "$rt" == "$t" ]; then return 0; fi
    done
    return 1
}

TARGET="pw-ac3-live-input"
TONE_DURATION=2
SAMPLE_RATE=48000
TMPDIR="${TMPDIR:-/tmp}"
WORK="${TMPDIR}/pw-ac3-validate-$$"

# ── Colors ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK"

# ── Helpers ────────────────────────────────────────────────────────────
ask_yn() {
    local prompt="$1"
    local answer
    while true; do
        echo -en "  ${CYAN}${prompt}${NC} [y/n] "
        read -r answer
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

gen_silence() {
    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i "anullsrc=r=${SAMPLE_RATE}:cl=mono:d=${TONE_DURATION}" \
        -c:a pcm_f32le -y "$1" 2>/dev/null
}

gen_tone() {
    local freq="$1" out="$2"
    if ! ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i "sine=frequency=${freq}:duration=${TONE_DURATION}:sample_rate=${SAMPLE_RATE}" \
        -c:a pcm_f32le -y "$out" 2>/dev/null; then
        echo -e "${RED}Error generating tone $out${NC}"
        return 1
    fi
}

gen_6ch() {
    # $1...$6 are mono wavs for FL/FR/FC/LFE/SL/SR, $7 is output
    if ! ffmpeg -hide_banner -loglevel error -nostdin \
        -i "$1" -i "$2" -i "$3" -i "$4" -i "$5" -i "$6" \
        -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
        -map "[a]" -c:a pcm_f32le -y "$7" 2>/dev/null; then
        echo -e "${RED}Error generating 6ch mix $7${NC}"
        return 1
    fi
}

play_to_target() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: File not found: $file${NC}"
        return 1
    fi
    if ! pw-play --target "$TARGET" "$file" 2>/dev/null; then
        echo -e "${RED}Error playing $file to $TARGET${NC}"
        # Try running without stderr suppression to show why
        pw-play --target "$TARGET" "$file" || true
        return 1
    fi
}

# ── Preflight ──────────────────────────────────────────────────────────
echo -e "${BOLD}═══ pw-ac3-live Interactive Audio Validation ═══${NC}"
echo ""

# Check dependencies
for cmd in ffmpeg pw-play pw-link; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Error: '$cmd' not found.${NC}"
        exit 1
    fi
done

# Check target node exists
if pw-link -i 2>/dev/null | grep -q "$TARGET"; then
    echo -e "  Target node: ${GREEN}$TARGET${NC} (found via PipeWire)"
else
    echo -e "  ${YELLOW}'$TARGET' not found (pw-ac3-live not running).${NC}"
    
    DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null || echo "")
    if [ -n "$DEFAULT_SINK" ]; then
        echo -e "  Default sink: ${CYAN}$DEFAULT_SINK${NC}"
    fi

    echo ""
    echo "  Select a target for audio validation:"
    echo "    1) Retry detection for $TARGET"
    echo "    2) Use default sink ($DEFAULT_SINK) [Default]"
    echo "    3) Enter custom target name/ID"
    echo "    4) List available sinks"
    echo -n "  > "
    read -r choice

    [ -z "$choice" ] && choice="2"

    case "$choice" in
        1)
            if ! pw-link -i 2>/dev/null | grep -q "$TARGET"; then
               echo -e "${RED}Error: '$TARGET' still not found.${NC}"
               exit 1
            fi
            ;;
        2)
            if [ -z "$DEFAULT_SINK" ]; then
                echo -e "${RED}Error: No default sink found.${NC}"
                exit 1
            fi
            TARGET="$DEFAULT_SINK"
            ;;
        3)
            echo -n "  Enter target name or ID: "
            read -r TARGET
            ;;
        4)
            echo ""
            pactl list sinks short
            echo ""
            echo -n "  Enter target name or ID: "
            read -r TARGET
            ;;
        *)
            echo "Cancelled."
            exit 1
            ;;
    esac
    echo -e "  Testing target: ${GREEN}$TARGET${NC}"
fi

# Check sink channel count
SINK_CHANNELS=$(pactl list sinks 2>/dev/null | awk -v t="$TARGET" '
    /^Sink #/ { in_sink=1; name="" }
    in_sink && /^\s+Name:/ { name=$2 }
    in_sink && name==t && /Sample Specification:/ { 
        for(i=1;i<=NF;i++) { if($i ~ /^[0-9]+ch$/) { print substr($i, 1, length($i)-2); exit } }
    }
' || echo "unknown")

if [[ "$SINK_CHANNELS" == "2" ]]; then
    echo -e "  ${YELLOW}Warning: Target sink is stereo (2 channels).${NC}"
    echo -e "  Surround channels (C, LFE, SL, SR) will likely be downmixed to FL/FR."
    echo -e "  Please verify sound *location*, not just presence."
fi
echo ""

# ── Generate test files ───────────────────────────────────────────────
echo -e "${BOLD}Generating test tones...${NC}"

gen_tone 440 "$WORK/tone_440.wav"   # A4
gen_tone 880 "$WORK/tone_880.wav"   # A5
gen_tone 1000 "$WORK/tone_1000.wav"   # 1kHz
gen_tone 100 "$WORK/tone_100.wav"   # LFE
gen_tone 660 "$WORK/tone_660.wav"   # E5
gen_tone 1100 "$WORK/tone_1100.wav" # C#6
gen_silence "$WORK/silence.wav"

# Full mix
gen_6ch "$WORK/tone_440.wav" "$WORK/tone_880.wav" "$WORK/tone_1000.wav" \
        "$WORK/tone_100.wav" "$WORK/tone_660.wav" "$WORK/tone_1100.wav" \
        "$WORK/mix_all.wav"

echo -e "  Done.\n"

# ── Results tracking ──────────────────────────────────────────────────
declare -A RESULTS
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

record() {
    local name="$1" result="$2"
    RESULTS["$name"]="$result"
    TOTAL=$((TOTAL + 1))
    case "$result" in
        PASS) PASSED=$((PASSED + 1)) ;;
        FAIL) FAILED=$((FAILED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# Test 1: Full 5.1 mix
# ══════════════════════════════════════════════════════════════════════
if should_run "1"; then
    echo -e "${BOLD}Test 1: Full 5.1 Mix${NC}"
    echo "  Playing a ${TONE_DURATION}s 5.1 surround mix through the pipeline..."
    play_to_target "$WORK/mix_all.wav"

    if ask_yn "Did you hear audio from your speakers/receiver?"; then
        record "Full 5.1 mix" "PASS"
        echo -e "  ${GREEN}✓${NC}\n"
    else
        record "Full 5.1 mix" "FAIL"
        echo -e "  ${RED}✗ No audio heard — check graph links, volumes, and receiver input.${NC}\n"
    fi
else
    record "Full 5.1 mix" "SKIP"
fi

# ══════════════════════════════════════════════════════════════════════
# Test 2: Per-channel sweep
# ══════════════════════════════════════════════════════════════════════
if should_run "2"; then
    echo -e "${BOLD}Test 2: Per-Channel Speaker Identification${NC}"
    echo "  Each channel plays a ${TONE_DURATION}s tone individually."
    echo ""

    CHANNELS=("FL" "FR" "FC" "LFE" "SL" "SR")
    FREQS=("440" "880" "1000" "100" "660" "1100")
    CHANNEL_NAMES=("Front Left" "Front Right" "Center" "Subwoofer (LFE)" "Surround Left" "Surround Right")

    for i in "${!CHANNELS[@]}"; do
        ch="${CHANNELS[$i]}"
        freq="${FREQS[$i]}"
        name="${CHANNEL_NAMES[$i]}"

        # Build per-channel file: only this channel has a tone, rest silent
        inputs=()
        for j in "${!CHANNELS[@]}"; do
            if [ "$j" -eq "$i" ]; then
                inputs+=("$WORK/tone_${freq}.wav")
            else
                inputs+=("$WORK/silence.wav")
            fi
        done

        gen_6ch "${inputs[@]}" "$WORK/test_${ch}.wav"

        echo -e "  ${CYAN}Playing: ${BOLD}${name}${NC} ${CYAN}(${ch}, ${freq}Hz)${NC}"
        play_to_target "$WORK/test_${ch}.wav"

        if ask_yn "Did you hear it from the ${name} speaker?"; then
            record "Channel ${ch} (${name})" "PASS"
            echo -e "  ${GREEN}✓${NC}\n"
        else
            record "Channel ${ch} (${name})" "FAIL"
            echo -e "  ${RED}✗${NC}\n"
        fi
    done
else
    # Mark skipped in results
    record "Channel FL (Front Left)" "SKIP"
    record "Channel FR (Front Right)" "SKIP"
    record "Channel FC (Center)" "SKIP"
    record "Channel LFE (Subwoofer (LFE))" "SKIP"
    record "Channel SL (Surround Left)" "SKIP"
    record "Channel SR (Surround Right)" "SKIP"
fi

if ! ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i "sine=frequency=1000:duration=0.2:sample_rate=${SAMPLE_RATE}" \
    -c:a pcm_f32le -y "$WORK/latency_beep.wav" 2>/dev/null; then
    echo -e "${RED}Error generating latency beep${NC}"
fi

# ══════════════════════════════════════════════════════════════════════
# Test 3: Manual Reaction Test
# ══════════════════════════════════════════════════════════════════════
if should_run "3"; then
    # ── Manual Reaction Test ──────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Mode: Reaction Test${NC}"
    echo "  Instruction: Press [ENTER] exactly when you hear the beep."
    echo ""
    echo "  Press [ENTER] when you are ready."
    read -r _
    echo ""

    LATENCY_SUM=0
    ATTEMPTS=3

    for i in $(seq 1 $ATTEMPTS); do
        echo -n "  Attempt $i/$ATTEMPTS: Get ready..."
        sleep $(( 1 + RANDOM % 2 ))  # Random sleep 1-2s

        # Start playing in background
        pw-play --target "$TARGET" "$WORK/latency_beep.wav" >/dev/null 2>&1 &
        
        # Capture start time (nanoseconds)
        START_TIME=$(date +%s%N)
        
        # Wait for user input
        read -r _
        
        # Capture end time
        END_TIME=$(date +%s%N)
        
        # Calculate delta in ms
        DELTA_NS=$((END_TIME - START_TIME))
        DELTA_MS=$((DELTA_NS / 1000000))
        
        echo -e "    Response time: ${BOLD}${DELTA_MS} ms${NC}"
        LATENCY_SUM=$((LATENCY_SUM + DELTA_MS))
    done

    AVG_LATENCY=$((LATENCY_SUM / ATTEMPTS))
    HUMAN_REACTION_MS=200
    ESTIMATED_AUDIO_LATENCY=$((AVG_LATENCY - HUMAN_REACTION_MS))
    if [ "$ESTIMATED_AUDIO_LATENCY" -lt 0 ]; then ESTIMATED_AUDIO_LATENCY=0; fi

    echo ""
    echo -e "  Average Response: ${BOLD}${AVG_LATENCY} ms${NC}"
    echo -e "  Estimated Audio Latency: ~${ESTIMATED_AUDIO_LATENCY} ms (assuming ${HUMAN_REACTION_MS}ms reaction time)"
    echo ""

    if [ "$ESTIMATED_AUDIO_LATENCY" -lt 150 ]; then
        record "Latency" "PASS"
        echo -e "  ${GREEN}✓ Latency seems OK.${NC}\n"
    elif [ "$ESTIMATED_AUDIO_LATENCY" -lt 500 ]; then
        record "Latency" "WARN"
        echo -e "  ${YELLOW}! Moderate latency detected.${NC}\n"
    else
        record "Latency" "FAIL"
        echo -e "  ${RED}✗ High latency detected (>500ms).${NC}\n"
        echo "  Suggestions:"
        echo "    - Reduce --buffer-size (try 960 or 480)"
        echo "    - Reduce --latency (try 64/48000)"
    fi
fi


# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════
echo -e "${BOLD}═══ Results ═══${NC}"
echo ""
printf "  %-35s %s\n" "Test" "Result"
printf "  %-35s %s\n" "---" "------"
for key in "Full 5.1 mix" \
           "Channel FL (Front Left)" \
           "Channel FR (Front Right)" \
           "Channel FC (Center)" \
           "Channel LFE (Subwoofer (LFE))" \
           "Channel SL (Surround Left)" \
           "Channel SR (Surround Right)" \
           "Latency"; do
    result="${RESULTS[$key]:-SKIP}"
    case "$result" in
        PASS) color="$GREEN" ;;
        FAIL) color="$RED" ;;
        *)    color="$YELLOW" ;;
    esac
    printf "  %-35s ${color}%s${NC}\n" "$key" "$result"
done

echo ""
echo -e "  ${BOLD}Total: ${PASSED}/${TOTAL} passed${NC}" \
        "$([ "$FAILED" -gt 0 ] && echo -e ", ${RED}${FAILED} failed${NC}")" \
        "$([ "$SKIPPED" -gt 0 ] && echo -e ", ${YELLOW}${SKIPPED} skipped${NC}")"

if [ "$FAILED" -gt 0 ]; then
    exit 1
else
    exit 0
fi
