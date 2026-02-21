# PipeWire AC-3 Live Encoder

`pw-ac3-live` is a real-time 5.1 LPCM to AC-3 (Dolby Digital) encoder for PipeWire/ALSA.

This project is only a proof of concept and is not intended for production use.
This project has been completely vibe-coded with AI.
I only have a limited knowledge of the tools used in this project (Rust, PipeWire, ALSA, ffmpeg) and in audio engineering in general.

## Purpose
Some HDMI sinks expose only stereo PCM but still accept AC-3 passthrough. This project creates a virtual 5.1 sink, encodes incoming audio to AC-3 with `ffmpeg`, and outputs an IEC61937 stream for playback.

The encoded stream is delivered through one of three possible output paths:
- **PipeWire Native** — plays back through a PipeWire output source node within the graph. Used on standard Linux desktops.
- **Direct ALSA** — writes the encoded stream directly to an ALSA hardware device from Rust, bypassing the PipeWire graph entirely. Used on platforms like the Steam Deck where PipeWire's ALSA sink plugin introduces unacceptable stuttering or scheduling jitter for encoded bitstreams.
- **Stdout Manual Pipe** — writes encoded IEC61937 bytes to `stdout` (`--stdout`) so you can manually route them to `pw-play`, `aplay`, or a file. Useful for debugging and custom pipelines.

This project has only been tested on the following path:
* Steam Deck → Valve Dock → HDMI → LG C4 TV → Optical (SPDIF) → Sony DAV-DZ340 (5.1) (uses `scripts/launch_steamdeck.sh`)
* Archlinux laptop → HDMI → LG C4 TV → Optical (SPDIF) → Sony DAV-DZ340 (5.1) (uses `scripts/launch_laptop.sh`)

## Requirements
- Rust toolchain
- PipeWire
- `ffmpeg` binary with AC-3 encoder and `spdif` muxer support
- PipeWire CLI tools for testing (`pw-play`, `pw-record`, `pw-link`, `pw-cli`, `pactl`)
- ALSA CLI tools for testing (`alsa-utils`)

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

# Path C: manually pipe stdout to PipeWire
cargo run --release -- --stdout \
  | pw-play --target <your-sink-node> --raw --format s16 --rate 48000 --channels 2 -

# Path C: manually pipe stdout to ALSA
cargo run --release -- --stdout \
  | aplay -D hw:0,8 -t raw -f S16_LE -r 48000 -c 2 --buffer-time=60000 --period-time=15000

# Write IEC61937 bytes directly to ALSA hardware (no PipeWire playback stream)
cargo run --release -- --alsa-direct --target hw:0,8 \
  --alsa-latency-us 60000 \
  --alsa-iec-card 0 \
  --alsa-iec-index 2

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
With `--alsa-direct`, `--target` is interpreted as an ALSA device string (for example `hw:0,8`).

`--stdout` mode drains buffered encoder output and exits cleanly on shutdown.
`--alsa-direct` enables direct ALSA playback from the Rust process (no `aplay` subprocess).
`--alsa-iec-card` and `--alsa-iec-index` select which IEC958 control the app toggles in direct ALSA mode. Both are required with `--alsa-direct`.

Latency-related knobs:
- `--buffer-size`: app ring buffer size in frames (default `4800`).
- `--output-buffer-size`: playback/output ring buffer size in frames (default: same as `--buffer-size`).
- `--latency`: PipeWire node latency target (default `64/48000`).
- `--ffmpeg-thread-queue-size`: FFmpeg input queue depth (default `128`).
- `--ffmpeg-chunk-frames`: frame batch size written to FFmpeg (default `128`).
- `--alsa-iec-card`: ALSA card used by `iecset`/`amixer` in direct ALSA mode (required with `--alsa-direct`).
- `--alsa-iec-index`: IEC958 index used by `iecset`/`amixer` in direct ALSA mode (required with `--alsa-direct`).
- `--profile-latency`: emits per-stage latency stats (`avg/p50/p95/max`) every second.

With the launcher scripts (choose the one for your platform):

```bash
# For Steam Deck (hardcoded for Valve Dock + specific HDMI sink)
./scripts/launch_steamdeck.sh

# For Laptop / General Linux (preconfigured PipeWire targets)
./scripts/launch_laptop.sh
```

> **Critical warning:**
> While `launch_steamdeck.sh` is running, **do not suspend/sleep** the system and **do not disconnect HDMI**.
> Doing so can leave PipeWire/ALSA card profiles in an inconsistent state (no audio, wrong sink, or noisy output) until manual recovery or reboot.
> Always stop the script cleanly with `Ctrl+C` before suspend, dock/undock, or HDMI cable changes.

**Steam Deck Specifics (`launch_steamdeck.sh`):**
- **Output Path**: **Direct ALSA** (Rust ALSA writer to `hw:0,8`).
- **Why?**: PipeWire's ALSA sink introduces choppy audio/stuttering on the Deck.
- **Hardcoded card/sink IDs**: Aligns with Valve Dock + Steam Deck internals:
  - HDMI card: `alsa_card.pci-0000_04_00.1`
  - Internal speaker card: `alsa_card.pci-0000_04_00.5-platform-nau8821-max`
  - Loopback sink: `alsa_loopback_device.alsa_output.pci-0000_04_00.1.hdmi-stereo-extra2`
- **Behavior**: The script disables the HDMI card profile to release `hw:0,8` and restores PipeWire defaults on exit; in `--alsa-direct` mode the app itself configures IEC958 Non-Audio + ALSA mixer unmute and restores IEC958 Audio mode on shutdown.

**Laptop/Generic Specifics (`launch_laptop.sh`):**
- **Output Path**: **PipeWire Native** (in-graph playback stream).
- **Preconfigured Targets**: Uses fixed `CARD_NAME`, `TARGET_SINK`, `CONNECT_TARGET`, and `TARGET_SINK_INDEX` values in the script (edit these for your machine).
- **Runtime Defaults**: Starts `pw-ac3-live` with `--latency 64/48000`, `--ffmpeg-thread-queue-size 16`, and `--ffmpeg-chunk-frames 64`.
- **Startup/Cleanup Automation**: Sets HDMI profile + AC-3 sink format, forces sink volume to `100%`, routes active streams to `pw-ac3-live-input`, links `pw-ac3-live-output` to the configured sink, then restores original default sink/card profile on exit.

**Manual/Advanced Specifics (Path C via `--stdout`):**
- **Output Path**: **Stdout Manual Pipe**.
- **Use case**: You want to control the final transport yourself (`pw-play`, `aplay`, `tee`, custom processing).
- **Trade-off**: You manage process chaining and lifecycle manually.

## Manual Setup
If you prefer to configure everything manually or need to reset your setup from scratch, see [docs/MANUAL_SETUP.md](docs/MANUAL_SETUP.md).


## Troubleshooting
For common issues (noise, silence, lag) and their fixes, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).


## Runtime nodes
- Input node: `pw-ac3-live-input` (PipeWire sink, 6 channels, F32LE)
- Output node: `pw-ac3-live-output` (PipeWire source, S16LE IEC61937 payload) unless `--stdout` or `--alsa-direct` is enabled

The capture side supports both layouts commonly exposed by PipeWire:
- single interleaved buffer (`datas=1`, typically with stride),
- multi-buffer planar input.

## Testing
For detailed testing instructions, including automated tests and local pipelines, see [docs/TESTING.md](docs/TESTING.md).


## License
MIT / Apache-2.0
