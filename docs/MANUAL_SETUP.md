# Manual Setup Guide

This guide details the manual steps to configure the AC-3 encoder pipeline from scratch. It is useful for debugging, understanding the underlying components, or setting up on a new platform where the automated scripts might fail.

## Part 1: Preparation

### 1. Close Existing Instances
Ensure no other instances of `pw-ac3-live` or `aplay` are locking the device.
```bash
pkill -INT -f pw-ac3-live || true
pkill -INT -f aplay || true
```

### 2. Verify Tools
You will need the following tools installed and in your PATH:
```bash
command -v cargo ffmpeg wpctl pw-link pactl iecset aplay
```
*Note: `iecset` and `aplay` are part of `alsa-utils`.*

### 3. Build the Project
```bash
cargo build --release
```

---

## Part 2: Choose Your Path

There are two ways to output the encoded audio. Choose the one that matches your use case:

| Path | Best For | Description |
| :--- | :--- | :--- |
| **Path A: PipeWire Native** | **Desktop Linux** (Laptop, Workstation) | The encoder outputs to a PipeWire node. PipeWire handles the routing to the HDMI sink. Easier to manage, integrates with desktop volume controls. |
| **Path B: Direct ALSA** | **Steam Deck**, Appliances | The encoder pipes output directly to `aplay`, bypassing PipeWire's HDMI sink. **Required** on Steam Deck to avoid stuttering/jitter caused by PipeWire's scheduling with the hardware driver. |

---

## Part 3: Path A - PipeWire Native (Desktop)

Standard setup for most Linux desktops.

### 1. Set HDMI Profile to Stereo
`pw-ac3-live` encapsulates 5.1 AC-3 data into a 2-channel 48kHz PCM stream (S16LE).
**Do not** use Surround 5.1/7.1 profiles; they will interpret the data as noise on Front Left/Right.

```bash
# Find your card name
pactl list cards short

# Set to HDMI Stereo + Analog Input (standard profile)
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo+input:analog-stereo
```

### 2. Configure the HDMI Sink
You must force the sink to accept AC-3 passthrough (IEC61937) and set volume to 100%.

```bash
# Find sink index
pactl list sinks short | grep hdmi-stereo

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
# Get sink name
pactl list sinks short | grep hdmi-stereo

# Run
RUST_LOG=info cargo run --release -- \
  --target alsa_output.pci-0000_00_1f.3.hdmi-stereo \
  --buffer-size 960 \
  --latency 32/48000
```

---

## Part 4: Path B - Direct ALSA (Steam Deck / Appliance)

This path gives the encoder exclusive access to the HDMI hardware, bypassing PipeWire's mixing/scheduling for the output stage.

### 1. Find the Hardware Device
You need the ALSA hardware card and device numbers (e.g., `hw:0,3`).

```bash
aplay -l | grep HDMI
# Output example: card 0: PCH [HDA Intel PCH], device 3: HDMI 0 [HDMI 0]
```
 In this example, the device is `hw:0,3`.

### 2. Set "Non-Audio" Bit (The "Zombie State" Fix)
For AC-3 passthrough to work reliably on some hardware (like Steam Deck), you must set the IEC958 status bits to "Non-Audio". If this is set to "Audio" (PCM), the receiver might try to decode the burst as PCM noise.

You often need to try multiple indices (0-3) as mapping varies.
```bash
# Replace '-c 0' with your card index found in step 1.
# Run for indices 0, 1, 2, 3 to be safe.
iecset -c 0 -n 0 audio off rate 48000
iecset -c 0 -n 1 audio off rate 48000
iecset -c 0 -n 2 audio off rate 48000
iecset -c 0 -n 3 audio off rate 48000
```

### 3. Run the Pipeline
We pipe the encoder's stdout directly to `aplay`.

```bash
# --stdout mode writes raw IEC61937 frames to standard output
RUST_LOG=info cargo run --release -- --stdout \
  --buffer-size 6144 \
  --output-buffer-size 3072 \
  --ffmpeg-thread-queue-size 32 \
| aplay -D hw:0,3 \
  --disable-resample --disable-format --disable-channels --disable-softvol \
  -v -t raw -f S16_LE -r 48000 -c 2 \
  --buffer-time=60000 --period-time=15000
```

*Note: The buffer sizes above are tuned for the Steam Deck. If you experience stutters, try increasing `buffer-time`.*

---

## Part 5: Routing & Verification

Once the encoder is running (via Path A or B), a new PipeWire sink named **"AC-3 Encoder Input"** (`pw-ac3-live-input`) will appear.

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

**Low Latency Profile (Laptop):**
```bash
--buffer-size 960 --latency 32/48000 --ffmpeg-thread-queue-size 16
```

**Stable Profile (Steam Deck):**
```bash
--buffer-size 3072 --output-buffer-size 6144 --ffmpeg-thread-queue-size 32
```
