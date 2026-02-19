# PipeWire AC-3 Live Encoder

`pw-ac3-live` is a real-time 5.1 LPCM to AC-3 (Dolby Digital) encoder for PipeWire/ALSA.

This project is only a proof of concept and is not intended for production use.
This project has been completely vibe-coded with AI.
I only have a limited knowledge of the tools used in this project (Rust, PipeWire, ALSA, ffmpeg) and in audio engineering in general.

## Purpose
Some HDMI sinks expose only stereo PCM but still accept AC-3 passthrough. This project creates a virtual 5.1 sink, encodes incoming audio to AC-3 with `ffmpeg`, and outputs an IEC61937 stream for playback.

The encoded stream is delivered through one of two co-equal output paths:
- **PipeWire Native** — plays back through a PipeWire output source node within the graph. Used on standard Linux desktops.
- **Direct ALSA** — pipes the encoded stream to `aplay` for exclusive hardware access, bypassing the PipeWire graph entirely. Used on platforms like the Steam Deck where PipeWire's ALSA sink plugin introduces unacceptable stuttering or scheduling jitter for encoded bitstreams.

This project has only been tested on the following path: 
* Steam Deck → Valve Dock → HDMI → LG C4 TV → Optical (SPDIF) → Sony DAV-DZ340 (5.1) (uses `scripts/launch_live_steamdeck.sh`)
* Archlinux laptop → HDMI → LG C4 TV → Optical (SPDIF) → Sony DAV-DZ340 (5.1) (uses `scripts/launch_live_laptop.sh`)

## Requirements
- Rust toolchain
- PipeWire
- `ffmpeg` binary with AC-3 encoder and `spdif` muxer support
- PipeWire CLI tools for local testing (`pw-play`, `pw-record`, `pw-link`, `pw-cli`, `pactl`)

## Build
```bash
cargo build --release
```

## Run
```bash
# Default PipeWire playback mode
cargo run --release

# With logs
RUST_LOG=info cargo run --release
```

### CLI options
```bash
# Explicit playback target by node name
cargo run --release -- --target alsa_output.pci-0000_03_00.1.hdmi-stereo

# Explicit playback target by numeric object ID
cargo run --release -- --target 42

# Write IEC61937 bytes to stdout (no PipeWire playback stream)
cargo run --release -- --stdout > output.spdif

# Lower latency profile (good starting point)
cargo run --release -- --target <your-hdmi-node> \
  --buffer-size 960 \
  --output-buffer-size 960 \
  --latency 32/48000 \
  --ffmpeg-thread-queue-size 16 \
  --ffmpeg-chunk-frames 128

# Enable per-stage latency profiling logs (once per second)
cargo run --release -- --target <your-hdmi-node> --profile-latency
```

`--target` accepts either a node name or a numeric object ID. Numeric values are applied to both the stream connect target and `target.object` properties. Name values are applied as `target.object`.

`--stdout` mode drains buffered encoder output and exits cleanly on shutdown.

Latency-related knobs:
- `--buffer-size`: app ring buffer size in frames (default `4800`).
- `--output-buffer-size`: playback/output ring buffer size in frames (default: same as `--buffer-size`).
- `--latency`: PipeWire node latency target (default `64/48000`).
- `--ffmpeg-thread-queue-size`: FFmpeg input queue depth (default `128`).
- `--ffmpeg-chunk-frames`: frame batch size written to FFmpeg (default `128`).
- `--profile-latency`: emits per-stage latency stats (`avg/p50/p95/max`) every second.

With the launcher scripts (choose the one for your platform):

```bash
# For Steam Deck (hardcoded for Valve Dock + specific HDMI sink)
./scripts/launch_live_steamdeck.sh

# For Laptop / General Linux (dynamic detection)
./scripts/launch_live_laptop.sh
```

### Script Configuration

Both scripts support environment variable overrides, but defaults differ.

**Common Options:**
```bash
# Optional: lower output ring independently (frames)
PW_AC3_OUTPUT_BUFFER_SIZE=960 ./scripts/launch_live_laptop.sh

# Optional: force a specific physical HDMI sink node
PW_AC3_TARGET_SINK=alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2 ./scripts/launch_live_steamdeck.sh

# Optional (loopback-only setups): force app target and link target separately
PW_AC3_APP_TARGET=alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2 \
PW_AC3_CONNECT_TARGET=alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2 \
./scripts/launch_live_laptop.sh
```

**Steam Deck Specifics (`launch_live_steamdeck.sh`):**
- **Output Path**: **Direct ALSA** (`aplay` to `hw:0,8`).
- **Why?**: PipeWire's ALSA sink introduces choppy audio/stuttering on the Deck.
- **Hardcoded defaults**: Aligns with Valve Dock hardware on Steam Deck.
- **Behavior**: Takes exclusive control of the HDMI audio device, disables the card profile, configures IEC958 Non-Audio bits, and restores state on exit.

**Laptop/Generic Specifics (`launch_live_laptop.sh`):**
- **Output Path**: **PipeWire Native** (in-graph playback stream).
- **Dynamic Detection**: Scans for `pci` sound cards and `hdmi-stereo` sinks.
- **Lower Latency**: Defaults to `960` buffer size / `64` frames latency for desktop responsiveness.
- **Profile Auto-Set**: Attempts to find and set `output:hdmi-stereo` profile on the detected card.

## Manual Setup
If you prefer to configure everything manually or need to reset your setup from scratch, see [docs/MANUAL_SETUP.md](docs/MANUAL_SETUP.md).


## Troubleshooting
For common issues (noise, silence, lag) and their fixes, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).


## Runtime nodes
- Input node: `pw-ac3-live-input` (PipeWire sink, 6 channels, F32LE)
- Output node: `pw-ac3-live-output` (PipeWire source, S16LE IEC61937 payload) unless `--stdout` is enabled

The capture side supports both layouts commonly exposed by PipeWire:
- single interleaved buffer (`datas=1`, typically with stride),
- multi-buffer planar input.

## Testing
For detailed testing instructions, including automated tests and local pipelines, see [docs/TESTING.md](docs/TESTING.md).


## License
MIT / Apache-2.0
