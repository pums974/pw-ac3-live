#!/bin/bash
set -e

# ID of the card (usually 0 for Generic)
CARD_NAME="alsa_card.pci-0000_04_00.1"
ALSA_DEVICE="hw:0,8"
PROFILE_NAME="output:hdmi-stereo-extra2"

echo "=== Testing Direct ALSA Sink Loading ==="

# 1. Disable current profile to free the device
echo "Disabling card profile to free device $ALSA_DEVICE..."
pactl set-card-profile "$CARD_NAME" off
sleep 2

# 2. Check if device is free
echo "Checking if device is free..."
if fuser -v /dev/snd/pcmC0D8p; then
    echo "Error: Device still busy!"
    pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME"
    exit 1
fi

# 3. Load direct sink
echo "Loading module-alsa-sink..."
MODULE_ID=$(pactl load-module module-alsa-sink device="$ALSA_DEVICE" sink_name=direct_test format=s16le rate=48000 channels=2)
echo "Loaded module ID: $MODULE_ID"
sleep 1

# 4. Play test sound
echo "Playing test sound to 'direct_test'..."
# Generate 1 second of noise or sine if possible, or use existing file
# We don't have a guaranteed wav file, checking...
TEST_WAV="/usr/share/sounds/freedesktop/stereo/audio-channel-front-center.oga"
if [ -f "$TEST_WAV" ]; then
    pw-play --target direct_test --volume 0.5 "$TEST_WAV"
else
    # Synthesize simple tone with pw-play if possible? No, pw-play plays files.
    # Try speaker-test?
    speaker-test -D direct_test -c 2 -t sine -f 440 -l 1
fi

# 5. Cleanup
echo "Unloading module..."
pactl unload-module "$MODULE_ID"
sleep 1

echo "Restoring profile..."
pactl set-card-profile "$CARD_NAME" "$PROFILE_NAME"

echo "Done."
