#!/bin/bash
set -e

# Target the AC-3 Encoder Input
TARGET="pw-ac3-live-input"

echo "Generating 5.1 test file..."
ffmpeg -y -f lavfi -i "sine=frequency=1000:duration=5" \
       -f lavfi -i "sine=frequency=1000:duration=5" \
       -f lavfi -i "sine=frequency=1000:duration=5" \
       -f lavfi -i "sine=frequency=1000:duration=5" \
       -f lavfi -i "sine=frequency=1000:duration=5" \
       -f lavfi -i "sine=frequency=1000:duration=5" \
       -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
       -map "[a]" -c:a pcm_f32le test_5.1.wav

echo "Playing 5.1 test file to $TARGET..."
pw-play --target "$TARGET" test_5.1.wav

echo "Done. Did you hear sound from all speakers?"
