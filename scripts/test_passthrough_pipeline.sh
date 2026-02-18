#!/usr/bin/env bash
# Passthrough Latency Test
# 
# 1. Launches pw-ac3-live in PASSTHROUGH mode (No FFmpeg, no AC-3).
#    It captures audio and copies PCM directly to the output.
# 2. Plays a test tone into the capture node.
# 3. If latency is ~1s, then AC-3 encoding was adding 3s (unlikely).
#    If latency is ~4s, then Capture/Input buffering is the culprit.

set -euo pipefail

cleanup() {
    echo "Stopping pw-ac3-live..."
    kill $(jobs -p) 2>/dev/null || true
    pkill -f "pw-ac3-live" || true
}
trap cleanup EXIT

echo "=== Passthrough Latency Test ==="
echo "Starting pw-ac3-live in PASSTHROUGH/DIRECT PCM mode..."
echo "This bypasses FFmpeg entirely."
echo ""

export PW_AC3_PASSTHROUGH=1
export PW_AC3_DIRECT_ALSA_FALLBACK=1

/home/deck/Downloads/pw-ac3-live-steamdeck-0.1.0/scripts/launch_live.sh &
LAUNCH_PID=$!

echo "Waiting 10s for pipeline to stabilize..."
sleep 60

echo ""
echo ">>> Ready to play test tones! <<<"
echo "Audio is being captured by PipeWire, passed through pw-ac3-live (no encoding), and played to hardware."
echo ""
echo "Listen for the beep. If it's delayed by 3-4s, the issue is CAPTURE side."
echo "(Generating 1kHz tone... press Ctrl+C to stop)"

# Generate continuous tone and play to default sink (which should be pw-ac3-live-input)
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -f s16le -ac 2 -ar 48000 - \
    2>/dev/null | \
    pw-play --rate 48000 --channels 2 --format s16 --target "pw-ac3-live-input" -

wait $LAUNCH_PID
