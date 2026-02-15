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
