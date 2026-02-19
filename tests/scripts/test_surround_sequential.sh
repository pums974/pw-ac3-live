#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."


TARGET="pw-ac3-live-input"

echo "Generating sequential 5.1 test file (approx 10MB)..."

# Generate 1-second silence and 1-second tone
# We will combine these to create separate tracks for each channel

# Function to create a channel file with tone at specific slot
# This is a bit complex with pure ffmpeg filters in one go, 
# so we'll generate a single 6-channel file where the tone moves.

# 1. Create a 3s white noise burst
ffmpeg -y -f lavfi -i "anoisesrc=d=2:c=white:r=48000" -c:a pcm_f32le beep.wav

# 2. Create 2s silence
ffmpeg -y -f lavfi -i "anullsrc=r=48000:cl=mono:d=2" -c:a pcm_f32le silence.wav

# 3. Create a composite file
# Structure: [FL][FR][FC][LFE][SL][SR]
# Total duration: 12s
# 0-2s: FL
# 2-4s: FR
# ...

echo "Building 6-channel sequence..."

# We need 6 inputs. For each 2s segment, only one channel has 'beep.wav', others have 'silence.wav'.
# Actually, easier to use -filter_complex to route a single moving source? 
# No, let's just make 6 separate mono files that are 12s long, with silence/beep in right places?
# Too slow.

# Simpler approach: 
# Play separate files to specific channel maps? 
# pw-play --channel-map=... is tricky if the sink is 6ch.

# Let's try creating a single polyphonic file with padding.
# Channel FL: Beep + 10s silence
# Channel FR: 2s silence + Beep + 8s silence
# ...

# Actually, let's just generate 6 separate short encoded valid 5.1 wavs, 
# where 5 channels are silent?
# Then play them one by one.

create_channel_test() {
    CH_NAME=$1
    # Map for join filter: FL=c0, FR=c1, FC=c2, LFE=c3, SL=c4, SR=c5
    # We input 6 streams.
    # $2...$7 are the input files (beep.wav or silence.wav)
    
    echo "Generating test for $CH_NAME..."
    ffmpeg -y \
        -i $2 -i $3 -i $4 -i $5 -i $6 -i $7 \
        -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" \
        -map "[a]" -c:a pcm_f32le "test_${CH_NAME}.wav"
}

# Create components
# beep.wav already created
# silence.wav already created

# FL
create_channel_test "FL"  beep.wav silence.wav silence.wav silence.wav silence.wav silence.wav
# FR
create_channel_test "FR"  silence.wav beep.wav silence.wav silence.wav silence.wav silence.wav
# FC
create_channel_test "FC"  silence.wav silence.wav beep.wav silence.wav silence.wav silence.wav
# LFE
create_channel_test "LFE" silence.wav silence.wav silence.wav beep.wav silence.wav silence.wav
# SL
create_channel_test "SL"  silence.wav silence.wav silence.wav silence.wav beep.wav silence.wav
# SR
create_channel_test "SR"  silence.wav silence.wav silence.wav silence.wav silence.wav beep.wav

echo "========================================"
echo "STARTING TEST SEQUENCE"
echo "========================================"

play_ch() {
    echo "Playing: $1"
    pw-play --target "$TARGET" "test_$1.wav"
    sleep 0.5
}

play_ch "FL"
play_ch "FR"
play_ch "FC"
play_ch "LFE"
play_ch "SL"
play_ch "SR"

echo "========================================"
echo "Test Complete."
