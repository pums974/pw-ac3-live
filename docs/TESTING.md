# Testing Guide

## Automated tests
Run all tests:

```bash
cargo test
```

Run focused suites:

```bash
cargo test --test encoder_tests
cargo test --test pipewire_client_tests
cargo test --test alsa_control_tests
./tests/scripts/test_ci_help.sh
./tests/scripts/test_ci_alsa_args.sh
```

Current regression coverage includes:
- encoder shutdown with output backpressure (full output ring, no consumer drain),
- safe audio buffer parsing assumptions for planar F32 buffers,
- PipeWire target selection behavior (`--target` by name and numeric ID),
- clean shutdown of `--stdout` output loop.

## Local end-to-end pipeline test
Use `tests/scripts/test_local_pipeline.sh` to verify the full path without requiring a real HDMI/AVR sink.

```bash
./tests/scripts/test_local_pipeline.sh
```

### Prerequisites
- Rust toolchain
- PipeWire and running user session
- `ffmpeg`
- `pw-play`, `pw-record`, `pw-link`, `pw-cli`, `pactl`

### What the script does
1. Builds the project in release mode.
2. Creates a null sink `pw-ac3-test-sink` (48kHz, stereo S16LE).
3. Starts `pw-ac3-live --stdout` and pipes stdout through `tee` to:
   - `intermediate.raw`,
   - `pw-play --target "$SINK_NAME" --raw --format s16 --rate 48000 --channels 2 -`.
4. Starts `pw-record` in sink-capture mode and captures to `output.spdif`.
5. Plays/generates a 6-channel test signal and links it to `pw-ac3-live-input`.
6. Stops recorder/pipeline cleanly, then validates output files and IEC61937 headers.

### Artifacts
- `output.spdif`: captured monitor output from the null sink.
- `intermediate.raw`: raw stdout stream from `pw-ac3-live`.
- `pw-ac3-live-pipeline.log`: pipeline start/runtime logs.
- `pw-play-input.log`, `ports.log`: debugging artifacts for link diagnostics.

### Notes
- The script uses explicit PID and process-group cleanup to avoid races and orphaned processes.
- IEC61937 framing is validated by scanning for the full preamble `72 f8 1f 4e`.
- `intermediate.raw` is the authoritative encoder bitstream artifact and must contain IEC61937 preambles.
- `output.spdif` is captured from the sink monitor/mix path and may not preserve bit-exact IEC preambles on all setups.

## Native PipeWire end-to-end test
Use `tests/scripts/test_pipewire_pipeline.sh` for strict validation of the native PipeWire output stream:

```bash
./tests/scripts/test_pipewire_pipeline.sh
```

This script:
1. Runs `pw-ac3-live` in native mode (creates `pw-ac3-live-output` source node).
2. Links feeder -> `pw-ac3-live-input` and `pw-ac3-live-output` -> test sink.
3. Records directly from `pw-ac3-live-output` to `output_pipewire.spdif`.
4. Requires IEC61937 preamble detection in `output_pipewire.spdif`.
