# Architecture & Design

## Overview
`pw-ac3-live` is designed to bridge the gap between modern multi-channel audio sources (games, media players) and legacy or restricted hardware sinks (HDMI ARC/SPDIF) on Linux/PipeWire systems.

## Data Flow Pipeline

```mermaid
graph LR
    A[PipeWire Source] -->|6ch f32 PCM| B(Capture Thread)
    B -->|Lock-free RingBuffer| C(Encoder Thread)
    C -->|AC-3 Encoded Bytes| D(Playback Thread)
    D -->|Path A: PipeWire Native| E[PipeWire Output Source]
    D -->|Path B: Direct ALSA| F[ALSA Hardware Sink]
    D -->|Path C: stdout| G[stdout]
```

## Threading Model

To ensure glitch-free audio, we strictly separate real-time (RT) tasks from compute-intensive or blocking tasks.

### 1. Capture Thread (RT-Safe)
*   **Context**: PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
*   **Graph Node**: Creates `pw-ac3-live-input` (Virtual 5.1 Sink to other apps).
*   **Constraints**:
    *   Avoid blocking operations.
    *   Avoid long critical sections.
    *   Keep callback work bounded to prevent xruns.
*   **Responsibility**:
    *   Read 6-channel capture input (`F32LE`) from PipeWire buffers.
    *   Parse either:
        * single interleaved buffer (`datas=1`, stride-based), or
        * multi-buffer planar layout.
    *   Validate buffer boundaries/alignment and write frame-aligned samples to the `InputRingBuffer`.

### 2. Encoder Mechanism (Subprocess)
*   **Component**: `ffmpeg` binary spawned as a child process.
*   **Responsibility**:
    *   Reads raw f32le 6-channel audio from stdin.
    *   Encodes to AC-3 at 640kbps.
    *   Encapsulates in IEC 61937 (S/PDIF) format.
    *   Writes S16LE stereo stream to stdout.

### 3. Feeder & Reader Threads
*   **Context**: Standard OS threads (`std::thread`).
*   **Responsibility**:
    *   **Feeder**: Moves data from InputRingBuffer to FFmpeg's stdin.
    *   **Reader**: Moves data from FFmpeg's stdout to OutputRingBuffer.
    *   **Shutdown behavior**: Handles output backpressure and exits promptly when shutdown is requested, even if the output ring is full.

### 4. Playback & Output Architecture

The encoded IEC 61937 stream is delivered to the hardware via one of three possible output paths. Paths A and B are handled by launcher scripts, while Path C is manual.

#### Path A: PipeWire Native
The standard output path for desktop Linux setups where PipeWire's ALSA plugin performs well.
*   **Used by**: `scripts/launch_laptop.sh`
*   **Context**: Playback Thread (RT-Safe), running in PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
*   **Mechanism**: Writes audio data to a PipeWire output buffer.
*   **Graph Node**: Creates `pw-ac3-live-output` (Audio/Source, 2ch S16LE, IEC61937).
*   **Volume**: The script attempts to force volumes to 100% (0dB). Software attenuation *must* be avoided to prevent bitstream corruption.
*   **Routing**: Standard PipeWire linking to a target sink.

#### Path B: Direct ALSA
The output path for platforms where PipeWire's ALSA sink plugin introduces unacceptable scheduling jitter for encoded bitstreams (e.g., the Steam Deck with Valve Dock).
*   **Used by**: `scripts/launch_steamdeck.sh`
*   **Mechanism**: The application writes encoded data directly to ALSA (`--alsa-direct --target <hw:X,Y>`) for exclusive hardware access.
*   **Graph Node**: No output node is created in the PipeWire graph.
*   **Exclusive Access Process**:
    1.  **Device Identification**: The script targets `hw:0,8` (Valve Dock HDMI).
    2.  **HDMI Profile Disabling**: The script disables the HDMI card profile (`alsa_card.pci-0000_04_00.1 -> off`) to release the ALSA device.
    3.  **IEC958 + Mixer Setup**: In `--alsa-direct`, the Rust app sets IEC958 status bits to "Non-Audio" (compressed) and unmutes required ALSA controls (configurable via `--alsa-iec-card` / `--alsa-iec-index`).
    4.  **Playback**: `pw-ac3-live` itself takes exclusive control of `hw:0,8`.
    5.  **Cleanup**: On exit, the app restores IEC958 status to "Audio" (PCM) and the script restores HDMI card/default sink routing.
*   **Volume**: Raw IEC61937 frames are sent directly through ALSA. Software volume is effectively bypassed.

#### Path C: Stdout Manual Pipe
The output path for custom/manual routing scenarios where the user controls the final sink process explicitly.
*   **Used by**: manual CLI invocation (`pw-ac3-live --stdout | ...`).
*   **Mechanism**: The application writes encoded IEC61937 bytes to `stdout`; the user pipes to tools like `pw-play`, `aplay`, or file capture.
*   **Graph Node**: No output node is created in the PipeWire graph.
*   **Examples**:
    1.  `pw-ac3-live --stdout | pw-play --raw --format s16 --rate 48000 --channels 2 -`
    2.  `pw-ac3-live --stdout | aplay -D hw:0,8 -t raw -f S16_LE -r 48000 -c 2`
*   **Use Case**: debugging, ad-hoc routing, and experimentation without changing launcher scripts.

## Launcher Architecture

The project splits launch logic into two distinct scripts for the production paths (A and B):

### 1. `scripts/launch_steamdeck.sh`
*   **Target Hardware**: Valve Steam Deck Docking Station.
*   **Output Path**: **Direct ALSA** (`pw-ac3-live --alsa-direct --target hw:0,8`).
*   **Behavior**:
    *   Hardcoded Steam Deck card IDs and loopback sink names (no runtime hardware discovery).
    *   Uses direct ALSA writes from Rust to avoid PipeWire scheduling jitter/stuttering on the Deck.
    *   Delegates IEC958 Non-Audio and ALSA mixer setup/restore to the Rust app while it runs.
    *   Restores HDMI profile/default sink during cleanup.

### 2. `scripts/launch_laptop.sh`
*   **Target Hardware**: Generic Linux desktop/laptop.
*   **Output Path**: **PipeWire Native** (in-graph playback stream).
*   **Behavior**:
    *   Uses preconfigured PipeWire/ALSA identifiers (`CARD_NAME`, `TARGET_SINK`, `CONNECT_TARGET`, `TARGET_SINK_INDEX`) with no runtime hardware discovery.
    *   Applies HDMI profile and AC-3 sink format, then launches `pw-ac3-live` with low-latency settings (`--latency 64/48000`, `--ffmpeg-thread-queue-size 16`, `--ffmpeg-chunk-frames 64`).
    *   Sets `pw-ac3-live-input` as default sink, moves active sink inputs, links FL/FR outputs to the configured sink, and restores original sink/profile state during cleanup.

### 3. Path C (No Launcher)
*   **Target**: advanced users / debugging workflows.
*   **Output Path**: **Stdout Manual Pipe** (`pw-ac3-live --stdout | ...`).
*   **Behavior**:
    *   No dedicated script; pipeline orchestration is manual.
    *   Useful when testing custom sinks or transport chains.
