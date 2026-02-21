# Manual Setup Guide

This guide details the manual steps to configure the AC-3 encoder pipeline from scratch. It is useful for debugging, understanding the underlying components, or setting up on a new platform where the automated scripts might fail.

## Part 1: Preparation

### 1. Close Existing Instances
Ensure no other instances of `pw-ac3-live` are locking the device.
```bash
pkill -INT -f pw-ac3-live || true
```

### 2. Verify Tools
Use the built-in environment validator. It checks required tools and prints the card/sink/hardware data you need for the next steps.

```bash
./scripts/validate_env.sh
```

What to copy from the report:
- **PipeWire Cards & Profiles**: card names + active profiles.
- **PipeWire Objects Tables**: sink node names and card/profile mappings.
- **ALSA Hardware**: `hw:X,Y` endpoints (look for HDMI entries).

If it reports failures, fix them first.

### 3. Build the Project
```bash
cargo build --release
```

---

## Part 2: Choose Your Path

There are three ways to output the encoded audio. Choose the one that matches your use case:

| Path | Best For | Description |
| :--- | :--- | :--- |
| **Path A: PipeWire Native** | **Desktop Linux** (Laptop, Workstation) | The encoder outputs to a PipeWire node. PipeWire handles the routing to the HDMI sink. Easier to manage, integrates with desktop volume controls. |
| **Path B: Direct ALSA** | **Steam Deck**, Appliances | The encoder writes output directly to ALSA (`--alsa-direct` + `--target hw:X,Y`), bypassing PipeWire's HDMI sink. **Required** on Steam Deck to avoid stuttering/jitter caused by PipeWire's scheduling with the hardware driver. |
| **Path C: Stdout Manual Pipe** | **Debug / Advanced users** | The encoder writes IEC61937 bytes to `stdout` (`--stdout`) and you manually pipe to `pw-play`, `aplay`, or files. Flexible but manual lifecycle/routing management. |

---

## Part 3: Path A - PipeWire Native (Desktop)

Standard setup for most Linux desktops.

### 1. Set HDMI Profile to Stereo
`pw-ac3-live` encapsulates 5.1 AC-3 data into a 2-channel 48kHz PCM stream (S16LE).
**Do not** use Surround 5.1/7.1 profiles; they will interpret the data as noise on Front Left/Right.

```bash
# From validate_env output:
#   - pick your HDMI card name from "PipeWire Cards & Profiles"
#   - use an HDMI stereo profile listed for that card

# Set to HDMI Stereo + Analog Input (standard profile)
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo+input:analog-stereo
```

### 2. Configure the HDMI Sink
You must force the sink to accept AC-3 passthrough (IEC61937) and set volume to 100%.

```bash
# From validate_env output:
#   - pick HDMI sink index from "PipeWire Objects Tables" (sink node names table)

# Force format (replace <SINK_INDEX> with the number from above)
pactl set-sink-formats <SINK_INDEX> 'ac3-iec61937, format.rate = "[ 48000 ]"'

# Set Volume to 100% (0dB) - CRITICAL!
# Any attenuation will corrupt the AC-3 bitstream.
pactl set-sink-volume <SINK_INDEX> 100%
pactl set-sink-mute <SINK_INDEX> 0
```

### 3. Run the Encoder
Target the HDMI sink by name.
```bash
# From validate_env output:
#   - pick sink node name from "PipeWire Objects Tables"

# Run
RUST_LOG=info cargo run --release -- \
  --target alsa_output.pci-0000_00_1f.3.hdmi-stereo \
  --buffer-size 960 \
  --latency 32/48000
```

---

## Part 4: Path B - Direct ALSA (Steam Deck / Appliance)

This path gives the encoder exclusive access to the HDMI hardware, bypassing PipeWire's mixing/scheduling for the output stage.

### 2. Release HDMI Card
Disable HDMI profile first to release the ALSA device.

```bash
HDMI_CARD=alsa_card.pci-0000_04_00.1

pactl set-card-profile "$HDMI_CARD" off
```

### 3. Run the Pipeline
Run the encoder with direct ALSA output (same defaults as the Steam Deck launcher).
In `--alsa-direct`, the app applies IEC958 Non-Audio + mixer setup and restores IEC958 Audio on exit.
Provide `--alsa-iec-card` and `--alsa-iec-index` explicitly.

```bash
APP_BIN=./target/release/pw-ac3-live
[ -x "$APP_BIN" ] || APP_BIN=./bin/pw-ac3-live

"$APP_BIN" --alsa-direct --target hw:0,8 \
  --alsa-latency-us 60000 \
  --alsa-iec-card 0 \
  --alsa-iec-index 2 \
  --latency 1536/48000 \
  --ffmpeg-thread-queue-size 4 \
  --ffmpeg-chunk-frames 1536
```

### 4. Cleanup / Restore
Restore card profiles/default sink when you stop.

```bash
pactl set-card-profile "$HDMI_CARD" output:hdmi-stereo-extra2
pactl set-default-sink alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2

if [ -n "$INTERNAL_PROFILE" ]; then
  pactl set-card-profile "$INTERNAL_CARD" "$INTERNAL_PROFILE"
fi
```

---

## Part 5: Path C - Stdout Manual Pipe

Use this path when you want full control over the final sink process.

### 1. Pipe to PipeWire Manually
```bash
APP_BIN=./target/release/pw-ac3-live
[ -x "$APP_BIN" ] || APP_BIN=./bin/pw-ac3-live

"$APP_BIN" --stdout \
  --latency 1536/48000 \
  --ffmpeg-thread-queue-size 4 \
  --ffmpeg-chunk-frames 1536 \
| pw-play --target <your-sink-node> --raw --format s16 --rate 48000 --channels 2 -
```

### 2. Pipe to ALSA Manually
```bash
APP_BIN=./target/release/pw-ac3-live
[ -x "$APP_BIN" ] || APP_BIN=./bin/pw-ac3-live

"$APP_BIN" --stdout \
  --latency 1536/48000 \
  --ffmpeg-thread-queue-size 4 \
  --ffmpeg-chunk-frames 1536 \
| aplay -D hw:0,8 -t raw -f S16_LE -r 48000 -c 2 \
  --buffer-time=60000 --period-time=15000
```

---

## Part 6: Routing & Verification

Once the encoder is running (via Path A, B, or C), a new PipeWire sink named **"AC-3 Encoder Input"** (`pw-ac3-live-input`) will appear.

### 1. Route Audio
Move your applications (Browser, Games, MediaPlayer) to use this new sink.

**GUI Method:**
- Open `pavucontrol` -> Playback tab.
- Change the output device for your app to "AC-3 Encoder Input".

**CLI Method (Set Default):**
```bash
# Find ID of the virtual sink
wpctl status | grep "AC-3 Encoder Input"

# Set as default (replace <ID>)
wpctl set-default <ID>
```

### 2. Verify Wiring
Check that apps are linked to the encoder input:
```bash
pw-link -l | grep "pw-ac3-live-input"
```
You should see:
```text
Firefox:output_FL -> pw-ac3-live-input:playback_FL
Firefox:output_FR -> pw-ac3-live-input:playback_FR
...
```

---

## Reference: Tuning Parameters

If you experience latency or dropouts, adjust these flags:

| Flag | Default | Description |
| :--- | :--- | :--- |
| `--buffer-size` | 4800 | Internal ring buffer size (frames). Lower = less latency, higher = more stability. |
| `--output-buffer-size` | =buffer-size | Output ring buffer size. Increase this first if you hear dropouts. |
| `--latency` | 64/48000 | PipeWire quantum target. Lower is better for latency but requires stable CPU. |
| `--ffmpeg-thread-queue-size` | 128 | FFmpeg input packet queue. |
| `--ffmpeg-chunk-frames` | 128 | Frame batch size written to FFmpeg. Higher values improve stability, lower values reduce burst latency. |

**Low Latency Profile (Laptop):**
```bash
--buffer-size 960 --latency 32/48000 --ffmpeg-thread-queue-size 16
```

**Launcher Default (Steam Deck script):**
```bash
--latency 1536/48000 --ffmpeg-thread-queue-size 4 --ffmpeg-chunk-frames 1536
```
