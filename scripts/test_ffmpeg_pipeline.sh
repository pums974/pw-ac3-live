#!/usr/bin/env bash
# Synthetic Pipeline Test: FFmpeg (Generator) -> Output Chain -> Hardware
#
# This tests the encoding and output latency WITHOUT PipeWire capture.
# It runs FFmpeg generating beep tones, piped through the EXACT same
# output chain as the main app (reduce_pipe_latency.py -> aplay).
#
# Usage: ./scripts/test_ffmpeg_pipeline.sh [hw:0,8]

set -euo pipefail

# --- COPY-PASTE HARDWARE DETECTION & CLEANUP FROM test_alsa_latency.sh ---
CARD_NAME=$(pactl list cards short | grep "alsa_card.pci" | grep "0000_04_00.1" | awk '{print $2}' || true)
if [ -z "$CARD_NAME" ]; then
    CARD_NAME=$(pactl list cards short | grep "alsa_card.pci" | head -n1 | awk '{print $2}' || true)
fi
echo "Detected Card: $CARD_NAME"

CURRENT_PROFILE=$(pactl list cards | grep -A 100 "Name: $CARD_NAME" | grep "Active Profile" | head -n1 | cut -d: -f2 | xargs)
echo "Current Profile: $CURRENT_PROFILE"

cleanup() {
    echo ""
    echo "Restoring profile '$CURRENT_PROFILE' for card '$CARD_NAME'..."
    pactl set-card-profile "$CARD_NAME" "$CURRENT_PROFILE"
}
trap cleanup EXIT

echo "Releasing device from PipeWire (setting profile to off)..."
pactl set-card-profile "$CARD_NAME" off
sleep 2
# -------------------------------------------------------------------------

DEVICE="${1:-hw:0,8}"
BUFFER_TIME="${PW_AC3_DIRECT_ALSA_BUFFER_TIME:-60000}"
PERIOD_TIME="${PW_AC3_DIRECT_ALSA_PERIOD_TIME:-15000}"

echo "=== FFmpeg Synthetic Latency Test ==="
echo "Device:      $DEVICE"
echo "Buffer time: ${BUFFER_TIME}us"
echo "Period time: ${PERIOD_TIME}us"
echo ""
echo "Generating 1kHz beeps (50ms duration) followed by 950ms silence."
echo "This is encoded to AC-3 by FFmpeg and piped to aplay via the python shim."
echo ""
echo ">>> If you hear beeps INSTANTLY after they appear on screen, latency is Low."
echo ">>> If you hear them 4 seconds later, latency is High."
echo ""

# FFmpeg command explanation:
# -re : Read input at native frame rate (simulates live capture)
# -f lavfi -i ... : Generate sine wave beeps on the fly
# -c:a ac3 ... : Encode to AC-3 (exact settings from main app)
# -f spdif : Encapsulate in IEC61937
# pipe:1 : Output to stdout

# We will generate a continuous 1kHz tone.
echo "Starting pipeline (CONTINUOUS TONE)..."
echo "Listen for when the sound STARTS."

ffmpeg \
    -re \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -c:a ac3 -b:a 640k \
    -f spdif \
    -fflags +nobuffer -flags +low_delay \
    pipe:1 \
    2>/dev/null | \
    python3 /home/deck/Downloads/pw-ac3-live-steamdeck-0.1.0/scripts/reduce_pipe_latency.py | \
    aplay -D "$DEVICE" \
    -f S16_LE -c 2 -r 48000 \
    --buffer-time="$BUFFER_TIME" \
    --period-time="$PERIOD_TIME" \
    -v &

# Wait for user interrupt
wait
