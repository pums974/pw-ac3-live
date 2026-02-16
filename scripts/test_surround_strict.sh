#!/bin/bash
# test_surround_strict.sh
# Forces 1:1 mapping of mono signals to specific 5.1 channels on pw-ac3-live-input

# Generate simple mono white noise signal
ffmpeg -y -f lavfi -i "anoisesrc=color=white:amplitude=0.1:duration=2" -c:a pcm_f32le -ar 48000 mono_noise.wav > /dev/null 2>&1

INPUT_NODE="pw-ac3-live-input"

echo "========================================"
echo "STRICT SURROUND TEST (1:1 MAPPING)"
echo "========================================"
echo "Target: $INPUT_NODE"

# SIMPLER: Use `pw-play --channel-map` explicitly.

echo "Playing to FL only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=FL mono_noise.wav
sleep 0.5

echo "Playing to FR only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=FR mono_noise.wav
sleep 0.5

echo "Playing to FC only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=FC mono_noise.wav
sleep 0.5

echo "Playing to LFE only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=LFE mono_noise.wav
sleep 0.5

echo "Playing to SL only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=SL mono_noise.wav
sleep 0.5

echo "Playing to SR only... (White Noise)"
pw-play --target="$INPUT_NODE" --channel-map=SR mono_noise.wav
sleep 0.5

echo "Done."
