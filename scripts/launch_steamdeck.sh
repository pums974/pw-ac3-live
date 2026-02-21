#!/usr/bin/env bash

APP_BIN="${PW_AC3_APP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/pw-ac3-live}"
APP_PID=""

pkill -INT -f "pw-ac3-live" > /dev/null 2>&1 || true
sleep 1

trap '
kill "${APP_PID:-999999}" > /dev/null 2>&1 || true
pkill -P "${APP_PID:-999999}" > /dev/null 2>&1 || true
pactl set-card-profile alsa_card.pci-0000_04_00.1 output:hdmi-stereo-extra2 > /dev/null 2>&1 || true
pactl set-default-sink alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2 > /dev/null 2>&1 || true
' INT TERM EXIT

pactl set-card-profile alsa_card.pci-0000_04_00.1 off > /dev/null 2>&1 || true

(
  "$APP_BIN" \
    --alsa-direct \
    --target "hw:0,8" \
    --alsa-latency-us "60000" \
    --alsa-iec-card "0" \
    --alsa-iec-index "2" \
    --latency "1536/48000" \
    --ffmpeg-thread-queue-size "4" \
    --ffmpeg-chunk-frames "1536" \
    > /dev/null 2>&1
) &
APP_PID=$!

sleep 1
pactl set-default-sink pw-ac3-live-input > /dev/null 2>&1 || true
pactl list sink-inputs short | cut -f1 | xargs -r -P 8 -I{} pactl move-sink-input {} pw-ac3-live-input > /dev/null 2>&1 || true
pactl set-sink-volume pw-ac3-live-input 100% > /dev/null 2>&1 || true
pactl set-sink-mute pw-ac3-live-input 0 > /dev/null 2>&1 || true

echo "pw-ac3-live started on hw:0,8 (PID $APP_PID). Ctrl+C to stop."
wait "$APP_PID"
