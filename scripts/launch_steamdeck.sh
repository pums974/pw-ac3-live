#!/usr/bin/env bash

APP_BIN="${PW_AC3_APP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/pw-ac3-live}"
APP_PID=""

pkill -INT -f "pw-ac3-live" > /dev/null 2>&1 || true
sleep 1

trap '
kill "${APP_PID:-999999}" > /dev/null 2>&1 || true
pkill -P "${APP_PID:-999999}" > /dev/null 2>&1 || true
iecset -c 0 -n 2 audio on > /dev/null 2>&1 || true
pactl set-card-profile alsa_card.pci-0000_04_00.1 output:hdmi-stereo-extra2 > /dev/null 2>&1 || true
pactl set-default-sink alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2 > /dev/null 2>&1 || true
' INT TERM EXIT

pactl set-card-profile alsa_card.pci-0000_04_00.1 off > /dev/null 2>&1 || true
iecset -c 0 -n 2 audio off rate 48000 > /dev/null 2>&1 || true
amixer -c 0 set Master unmute 100% > /dev/null 2>&1 || true
amixer -c 0 set PCM unmute 100% > /dev/null 2>&1 || true
amixer -c 0 set "IEC958,2" unmute > /dev/null 2>&1 || true

(
  "$APP_BIN" \
    --stdout \
    --latency "1536/48000" \
    --ffmpeg-thread-queue-size "4" \
    --ffmpeg-chunk-frames "1536" 2> /dev/null | aplay -D hw:0,8 \
    -t raw -f S16_LE -r 48000 -c 2 \
    --buffer-time="60000" \
    --period-time="15000" \
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
