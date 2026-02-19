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

## Component & Hardware Tests

These scripts help isolate issues to specific components (ALSA, FFmpeg, Hardware) when debugging.

### 1. Direct ALSA Hardware Test
- **Script**: `tests/scripts/test_direct_alsa_sink.sh`
- **Purpose**: Verifies that the Steam Deck's specific hardware device (`hw:0,8`) can be opened and used exclusively.
- **Action**: Disables PipeWire on the card to free the device, loads a standard `module-alsa-sink` on it, and plays a test tone.
- **Use Case**: Run this if `pw-ac3-live` fails to open the ALSA device or if you suspect another process is blocking it.

### 2. Surround Channel Check
- **Script**: `tests/scripts/test_surround_sequential.sh`
- **Purpose**: Verifies correct 5.1 channel mapping.
- **Action**: Generates a test pattern where a tone moves sequentially: FL -> FR -> FC -> LFE -> SL -> SR.
- **Use Case**: Run this to ensure your AV receiver is correctly mapping the AC-3 channels to speakers.

### 3. ALSA Latency Isolation
- **Script**: `tests/scripts/test_alsa_latency.sh`
- **Purpose**: Measures the baseline latency of the hardware/HDMI link + AVR, excluding PipeWire and `pw-ac3-live`.
- **Action**: Generates beeps in Python and pipes them directly to `aplay`.
- **Latency Check**: If beeps are delayed here, the issue is in the OS/Hardware configuration, not the encoder.

### 4. FFmpeg Encoding Latency
- **Script**: `tests/scripts/test_ffmpeg_pipeline.sh`
- **Purpose**: Isolates latency introduced specifically by the FFmpeg AC-3 encoder.
- **Action**: Runs a synthetic pipeline: `Generator -> FFmpeg -> aplay` (bypassing PipeWire).
- **Latency Check**: If this is high but ALSA Latency is low, the issue is in the FFmpeg encoder settings.

### 5. Passthrough Latency Test
- **Script**: `tests/scripts/test_passthrough_pipeline.sh`
- **Purpose**: Diagnostic mode to bypass FFmpeg encoding entirely.
- **Action**: Launches `pw-ac3-live` in a special mode where it captures audio but copies it directly to the output without AC-3 encoding.
- **Latency Check**: If latency remains high here, the bottleneck is in the PipeWire capture path or buffering, not the encoder.

### 6. Basic Surround Test
- **Script**: `tests/scripts/test_surround.sh`
- **Purpose**: Quick audible verification of all 5.1 channels simultaneously.
- **Action**: Plays a 6-channel sine wave where all channels are active at once.
- **Use Case**: Simple "is it working at all?" check.

### 7. Strict Surround Mapping Test
- **Script**: `tests/scripts/test_surround_strict.sh`
- **Purpose**: Verifies 1:1 channel mapping precision.
- **Action**: Plays white noise to ONE channel at a time (FL, then FR, etc.) using explicit `pw-play --channel-map`.
- **Latency Check**: Use this to confirm that "Front Left" audio actually comes out of the "Front Left" speaker (and nowhere else).

## Debugging Scripts

These helper scripts dump system state for troubleshooting.

### 1. General Audio Device Dump
- **Script**: `scripts/debug_audio_devices.sh`
- **Purpose**: Snapshots the current state of ALSA cards, PipeWire nodes, and WirePlumber status.
- **Use Case**: Run this and attach the output when reporting issues about missing devices.

### 2. Low-Level ALSA Diagnostics
- **Script**: `scripts/debug_alsa_diagnostics.sh`
- **Purpose**: Inspects hardware-level ALSA state.
- **Action**: Runs `aplay -l`, `pactl list sinks`, and a `pw-top` snapshot.
- **Use Case**: Useful for checking if the HDMI card is detected by the kernel but not by higher-level sound servers.
