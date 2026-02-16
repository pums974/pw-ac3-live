# PipeWire AC-3 Live Encoder

`pw-ac3-live` is a real-time 5.1 LPCM to AC-3 (Dolby Digital) encoder for PipeWire.

## Purpose
Some HDMI sinks expose only stereo PCM but still accept AC-3 passthrough. This project creates a virtual 5.1 sink, encodes incoming audio to AC-3 with `ffmpeg`, and outputs an IEC61937 stream for playback.

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
```

`--target` accepts either a node name or a numeric object ID. Numeric values are applied to both the stream connect target and `target.object` properties. Name values are applied as `target.object`.

`--stdout` mode drains buffered encoder output and exits cleanly on shutdown.

## Fresh Start (Recommended)
Use this section if you want to reset your setup and start from zero.

### 0) Stop any previous run
```bash
pkill -INT -f pw-ac3-live || true
```

### 1) Confirm tools
```bash
command -v cargo ffmpeg wpctl pw-link pactl
```

### 2) Build
```bash
cargo build --release
```

### 3) Pick the correct HDMI profile (important)
`pw-ac3-live` outputs IEC61937/AC-3 payload over a stereo stream. If your card is in
`hdmi-surround` (or `hdmi-surround71`) profile, AC-3 data is often heard as loud noise.

List cards and active profile:
```bash
pactl list cards short
pactl list cards | rg -n "Name:|Profiles:|Active Profile:|output:hdmi-stereo|output:hdmi-surround"
```

Set HDMI stereo profile (replace card name if different):
```bash
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo+input:analog-stereo
```

### 4) Find the HDMI sink node name for `--target`
```bash
wpctl status
pactl list sinks short
```

Use the sink node ending in `hdmi-stereo`, for example:
- `alsa_output.pci-0000_00_1f.3.hdmi-stereo`

Optional detailed inspect:
```bash
wpctl inspect <HDMI_SINK_ID> | rg "node.name|node.description"
```

### 5) Force HDMI passthrough format to AC3 (critical)
If this step is skipped, many setups keep route codec at `PCM`, which produces static/noise.

```bash
# SINK_INDEX comes from `pactl list sinks short` (first column)
pactl set-sink-formats <SINK_INDEX> 'ac3-iec61937, format.rate = "[ 48000 ]"'
```

> [!IMPORTANT]
> **CRITICAL**: The HDMI sink volume must be set to **100% (0dB)**. Any attenuation (even 99%) will modify the bits of the AC-3 stream, causing the receiver to fail decoding and produce loud noise.
> ```bash
> pactl set-sink-volume <SINK_INDEX> 100%
> ```

Optional verification (advanced):
```bash
# Route props should show AudioIEC958Codec:AC3 instead of PCM
pw-cli e <DEVICE_ID> Route | rg "iec958Codecs|AudioIEC958Codec"
```

### 6) Start `pw-ac3-live`
```bash
RUST_LOG=info cargo run --release -- --target alsa_output.pci-0000_00_1f.3.hdmi-stereo
```

### 7) Route app audio into `pw-ac3-live-input`
The encoder only processes streams that go to the virtual sink `AC-3 Encoder Input`
(`node.name = pw-ac3-live-input`).

You can route audio in either UI:
- GNOME Settings -> Sound -> choose `AC-3 Encoder Input` as output device.
- `pavucontrol` -> Playback tab -> for each app stream, select `AC-3 Encoder Input`.

Or set default sink from CLI:
```bash
wpctl status
# then set default sink to the ID of "AC-3 Encoder Input"
wpctl set-default <AC3_ENCODER_INPUT_ID>
```

### 8) Verify graph wiring
Check routing:
```bash
pw-link -l | rg "pw-ac3-live-input:playback_|pw-ac3-live-output:capture_|hdmi-stereo:playback_"
```

You should see both patterns:
- `<app>:output_FL/FR -> pw-ac3-live-input:playback_*`
- `pw-ac3-live-output:capture_* -> <hdmi-stereo-node>:playback_FL/FR`

If the second pattern is missing, link manually:
```bash
./scripts/connect.sh alsa_output.pci-0000_00_1f.3.hdmi-stereo
```

> [!WARNING]
> **Exclusive Access**: Ensure no other applications (browsers, music players) are playing directly to the HDMI sink. They must play to `AC-3 Encoder Input`. Mixed PCM + AC-3 payload will cause artifacts or silence. Use `pw-link -d` to unlink rogue streams from the HDMI sink.

### 9) Receiver/TV audio mode
On AVR/TV, HDMI audio mode must allow compressed bitstream (`Bitstream`, `Auto`, passthrough).
If forced to `PCM`, AC-3 payload may be decoded as static/noise.

## Troubleshooting
### I hear loud noise/static
Most common causes:
- HDMI sink volume is **not** 100% (0dB).
- HDMI card profile is `hdmi-surround` / `hdmi-surround71` instead of `hdmi-stereo`.
- `--target` points to a surround sink node instead of `...hdmi-stereo`.
- HDMI sink formats are still `PCM` (route `iec958Codecs` did not switch to `AC3`).
- AVR/TV is set to PCM instead of bitstream/passthrough.

Fix sequence:
```bash
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo+input:analog-stereo
pactl list sinks short
pactl set-sink-formats <SINK_INDEX> 'ac3-iec61937, format.rate = "[ 48000 ]"'
# restart with the hdmi-stereo sink as --target
RUST_LOG=info cargo run --release -- --target <your-hdmi-stereo-node>
```

### I hear nothing
Check in order:
1. Encoder input is not being fed by apps.
2. `pw-ac3-live-output` is not linked to HDMI sink (Auto-link failed).
3. Other apps are hogging the HDMI sink (Exclusive access required).
4. Volumes/mute in `wpctl status`.

Fix:
```bash
# Force link
./scripts/connect.sh <hdmi-sink-name>
# Unlink others (example)
pw-link -d Firefox:output_FL <hdmi-sink-name>:playback_FL
```

Useful commands:
```bash
wpctl status
pw-link -l
```

### Audio drops or glitches
Increase ring buffer size:
```bash
cargo run --release -- --target <your-hdmi-stereo-node> --buffer-size 9600
```

### Sound is stereo only / All channels come from Front Speakers
If you hear surround content mixed down to your front speakers:
1. **Check Receiver Mode**: Ensure your AVR/Soundbar is in "Surround", "Dolby Digital", or "Straight" mode, not "Stereo" or "2ch".
2. **Verify Input**: Run the included verification script to test each channel independently:
   ```bash
   ./scripts/test_surround_sequential.sh
   ```
   If you hear the tones move correctly, the system is working, and your source application (e.g., Browser) is likely sending Stereo audio. This is normal behavior for stereo content (it is not upmixed by default).

## Return to Normal Desktop Audio
When done testing:
```bash
# Stop encoder (Ctrl+C in the running terminal)

wpctl status
# set default sink back to your regular HDMI/analog sink
wpctl set-default <REGULAR_SINK_ID>
```

In `pavucontrol`, move app streams back to your normal output device if needed.

## Runtime nodes
- Input node: `pw-ac3-live-input` (PipeWire sink, 6 channels, F32LE)
- Output node: `pw-ac3-live-output` (PipeWire source, S16LE IEC61937 payload) unless `--stdout` is enabled

The capture side supports both layouts commonly exposed by PipeWire:
- single interleaved buffer (`datas=1`, typically with stride),
- multi-buffer planar input.

## Testing
```bash
# Full test suite
cargo test

# Encoder-focused tests
cargo test --test encoder_tests

# PipeWire client behavior and parsing tests
cargo test --test pipewire_client_tests
```

Notable regression coverage includes:
- encoder shutdown under output backpressure,
- safe F32 parsing for planar and interleaved capture buffers (alignment/range assumptions),
- playback target resolution (`--target` numeric/name),
- stdout output loop shutdown behavior.

For end-to-end local verification, see `docs/TESTING.md`.

Quick integration scripts:
```bash
# Stdout pipeline + sink monitor capture (intermediate IEC validation)
./scripts/test_local_pipeline.sh

# Native PipeWire playback stream + direct output capture (strict IEC validation)
./scripts/test_pipewire_pipeline.sh
```

In local script output, `output.spdif` is captured from sink monitor/mix path and may not preserve
IEC sync words. `intermediate.raw` is the authoritative encoder bitstream artifact.

## Manual output connection helper
If you want to connect output ports manually from the shell:
```bash
./scripts/connect.sh <target-node-name-pattern>
```

## License
MIT / Apache-2.0
