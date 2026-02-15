# PipeWire AC-3 Live Encoder

A real-time 5.1 LPCM to AC-3 (Dolby Digital) encoder for PipeWire.

## Purpose
This project solves a hardware limitation on SteamOS (Steam Deck + Dock) where the HDMI sink (TV/AVR) only advertises 2-channel PCM support via EDID, but supports AC-3 passthrough. `pw-ac3-live` creates a virtual 5.1 surround sink, encodes the audio to AC-3 in real-time using FFmpeg, and outputs an IEC61937-encapsulated stream to the physical HDMI device.

## Architecture
- **Language**: Rust
- **Audio Server**: PipeWire (via `pipewire-rs`)
- **Encoding**: FFmpeg (via `ffmpeg-next`, `libavcodec`)
- **Concurrency**: Lock-free Ring Buffer (`rtrb`) connecting the RT-safe capture thread and the encoding thread.

## Prerequisites
- PipeWire
- FFmpeg libraries (`libavcodec`, `libavutil`, `libavformat`)
- Rust toolchain

## Usage

### Running Locally
```bash
# Build and run with release optimizations
cargo run --release

# To see debug logs
RUST_LOG=debug cargo run --release
```

## Testing & Verification

### Automated Tests
This project includes a suite of unit tests and a CI pipeline.

1.  **Run Tests Locally**:
    ```bash
    cargo test
    ```
    *Note: Requires `ffmpeg` to be installed.*

2.  **Continuous Integration**:
    Each push to `main` triggers a GitHub Actions workflow that runs `cargo test`, `cargo clippy`, and `cargo fmt`.

### Manual Verification
1.  **Run the Daemon**: Start the application using the command above.
2.  **Verify Nodes**:
    *   Run `pw-dot` or open a graph tool like `qpwgraph` or `Helvum`.
    *   Look for `pw-ac3-live-input` (Sink) and `pw-ac3-live-output` (Source).
3.  **Connect Audio**:
    *   Open PulseAudio Volume Control (`pavucontrol`).
    *   In the **Playback** tab, locate your 5.1 audio source (e.g., a game or media player).
    *   Change its output device to **AC-3 Encoder Input**.
4.  **Connect Output**:
    *   **Manual Action Required**: In `qpwgraph`/`Helvum`, explicitly connect `pw-ac3-live-output` to your physical HDMI/S/PDIF sink.
    *   Ensure your physical sink is set to a profile (like "Digital Stereo (IEC958)") that accepts the stream.

## Troubleshooting

-   **No Audio / Silence**:
    -   Check if the application is running (it logs "PipeWire loop running").
    -   Verify `pw-ac3-live-output` is connected to a physical sink.
    -   Ensure the physical sink is not muted.
-   **Underruns / Glitches**:
    -   Run in `--release` mode. Debug builds are too slow for real-time encoding.
    -   Check system load. AC-3 encoding is CPU intensive.
-   **FFmpeg Errors**:
    -   Check the terminal output. The application inherits FFmpeg's stderr, so you will see encoding errors directly.
    -   Ensure `ffmpeg` is installed and supports `ac3` and `spdif` muxer (`ffmpeg -formats | grep spdif`).

## License
MIT / Apache-2.0
