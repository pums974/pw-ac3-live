#!/usr/bin/env bash

APP_BIN="/Data/WORK/Projets/pw-ac3-live/target/release/pw-ac3-live"
APP_PID=""
ORIGINAL_DEFAULT_SINK="alsa_output.pci-0000_00_1f.3.hdmi-stereo"
CARD_NAME="alsa_card.pci-0000_00_1f.3"
ORIGINAL_CARD_PROFILE="output:hdmi-stereo+input:analog-stereo"
HDMI_PROFILE="output:hdmi-stereo+input:analog-stereo"
TARGET_SINK="alsa_output.pci-0000_00_1f.3.hdmi-stereo"
CONNECT_TARGET="alsa_output.pci-0000_00_1f.3.hdmi-stereo"
TARGET_SINK_INDEX="79"

pkill -INT -f "pw-ac3-live" > /dev/null 2>&1 || true
sleep 1

trap '
kill "${APP_PID:-999999}" > /dev/null 2>&1 || true
pkill -P "${APP_PID:-999999}" > /dev/null 2>&1 || true
pactl set-default-sink "$ORIGINAL_DEFAULT_SINK" > /dev/null 2>&1 || true
pactl set-card-profile "$CARD_NAME" "$ORIGINAL_CARD_PROFILE" > /dev/null 2>&1 || true
' INT TERM EXIT

pactl set-card-profile "$CARD_NAME" "$HDMI_PROFILE" > /dev/null 2>&1 || true
pactl set-sink-formats "$TARGET_SINK_INDEX" 'ac3-iec61937, format.rate = "[ 48000 ]"' > /dev/null 2>&1 || pactl set-sink-formats "$TARGET_SINK_INDEX" ac3-iec61937 > /dev/null 2>&1 || true
pactl set-sink-volume "$TARGET_SINK_INDEX" 100% > /dev/null 2>&1 || true
pactl set-sink-mute "$TARGET_SINK_INDEX" 0 > /dev/null 2>&1 || true

RUST_LOG=info "$APP_BIN" \
  --target "$TARGET_SINK" \
  --latency "64/48000" \
  --ffmpeg-thread-queue-size "16" \
  --ffmpeg-chunk-frames "64" 2> /dev/null &
APP_PID=$!

sleep 1
pactl set-default-sink pw-ac3-live-input > /dev/null 2>&1 || true
pactl list sink-inputs short | cut -f1 | xargs -r -P 8 -I{} pactl move-sink-input {} pw-ac3-live-input > /dev/null 2>&1 || true
pactl set-sink-volume pw-ac3-live-input 100% > /dev/null 2>&1 || true
pactl set-sink-mute pw-ac3-live-input 0 > /dev/null 2>&1 || true
for CH in FL FR; do
  pw-link "pw-ac3-live-output:output_${CH}" "${CONNECT_TARGET}:playback_${CH}" > /dev/null 2>&1 || true
done

echo "pw-ac3-live started on PipeWire sink $TARGET_SINK (PID $APP_PID). Ctrl+C to stop."
wait "$APP_PID"
