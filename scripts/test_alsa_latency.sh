#!/usr/bin/env bash
# Latency isolation test: bypass pw-ac3-live entirely.
# Plays a raw sine-wave beep directly through aplay to the HDMI device.
# If you hear the beep with multi-second delay, the latency is in ALSA/HDMI/AVR,
# NOT in pw-ac3-live.
#
# Usage: ./scripts/test_alsa_latency.sh [hw:0,8]

set -euo pipefail

DEVICE="${1:-hw:0,8}"
BUFFER_TIME="${2:-60000}"   # same as launch_live.sh default (60ms)
PERIOD_TIME="${3:-15000}"   # same as launch_live.sh default (15ms)

echo "=== ALSA Latency Isolation Test ==="
echo "Device:      $DEVICE"
echo "Buffer time: ${BUFFER_TIME}us"
echo "Period time: ${PERIOD_TIME}us"
echo ""

# Auto-detect the card name for the HDMI device (usually card 0)
CARD_NAME=$(pactl list cards short | grep "alsa_card.pci" | grep "0000_04_00.1" | awk '{print $2}' || true)
if [ -z "$CARD_NAME" ]; then
    # Fallback to first alsa card if specific one not found
    CARD_NAME=$(pactl list cards short | grep "alsa_card.pci" | head -n1 | awk '{print $2}' || true)
fi

echo "Detected Card: $CARD_NAME"

# Save current profile
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
sleep 2  # Wait for release

generate_beeps() {
    python3 -c "
import struct, math, sys, time

rate = 48000
channels = 2
beep_ms = 50
silence_ms = 950
freq = 1000  # 1kHz tone

beep_frames = int(rate * beep_ms / 1000)
silence_frames = int(rate * silence_ms / 1000)

# Generate one beep + silence cycle
beep = bytearray()
for i in range(beep_frames):
    sample = int(16000 * math.sin(2 * math.pi * freq * i / rate))
    frame = struct.pack('<hh', sample, sample)  # stereo
    beep += frame

silence = b'\x00' * (silence_frames * channels * 2)

cycle = bytes(beep + silence)

sys.stderr.write('Beep! (listen for it now)\\n')
sys.stderr.flush()

# Output 30 cycles (30 seconds)
for n in range(30):
    sys.stdout.buffer.write(cycle)
    sys.stdout.buffer.flush()
    sys.stderr.write(f'Beep #{n+1} sent at {time.strftime(\"%H:%M:%S\")}\\n')
    sys.stderr.flush()
"
}

echo ">>> Sending beeps NOW - count seconds until you hear each one <<<"
echo ""

generate_beeps | aplay -D "$DEVICE" \
    -f S16_LE -c 2 -r 48000 \
    --buffer-time="$BUFFER_TIME" \
    --period-time="$PERIOD_TIME" \
    -v 2>&1
