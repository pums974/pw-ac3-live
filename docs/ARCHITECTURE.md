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
    D -->|Path B: Direct ALSA| F[ALSA Hardware Sink via aplay]
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

The encoded IEC 61937 stream is delivered to the hardware via one of two co-equal output paths, selected by the platform-specific launcher script.

#### Path A: PipeWire Native
The standard output path for desktop Linux setups where PipeWire's ALSA plugin performs well.
*   **Used by**: `scripts/launch_live_laptop.sh`
*   **Context**: Playback Thread (RT-Safe), running in PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
*   **Mechanism**: Writes audio data to a PipeWire output buffer.
*   **Graph Node**: Creates `pw-ac3-live-output` (Audio/Source, 2ch S16LE, IEC61937).
*   **Volume**: The script attempts to force volumes to 100% (0dB). Software attenuation *must* be avoided to prevent bitstream corruption.
*   **Routing**: Standard PipeWire linking to a target sink.

#### Path B: Direct ALSA
The output path for platforms where PipeWire's ALSA sink plugin introduces unacceptable scheduling jitter for encoded bitstreams (e.g., the Steam Deck with Valve Dock).
*   **Used by**: `scripts/launch_live_steamdeck.sh`
*   **Mechanism**: The application writes encoded data to `stdout`. The launcher script pipes this directly to `aplay` for exclusive hardware access.
*   **Graph Node**: No output node is created in the PipeWire graph.
*   **Exclusive Access Process**:
    1.  **Device Identification**: The script targets `hw:0,8` (Valve Dock HDMI).
    2.  **Profile Disabling**: The script explicitly disables the card profile (`pactl set-card-profile ... off`) to release the ALSA device and unlock IEC958 controls.
    3.  **IEC958 Configuration**: The script uses `iecset` to force status bits to "Non-Audio" (compressed), bruteforcing all indices to ensure the setting takes effect.
    4.  **Playback**: `aplay` takes exclusive control of the device.
    5.  **Cleanup**: On exit, the script restores IEC958 status to "Audio" (PCM) and **restores the original Card Profile** to hand control back to PipeWire.
*   **Volume**: The script unmutes hardware controls (`amixer`) but relies on `aplay` passing raw data. Software volume is effectively bypassed.

## Launcher Architecture

The project splits launch logic into two distinct scripts, each implementing the output path best suited to its target platform:

### 1. `scripts/launch_live_steamdeck.sh`
*   **Target Hardware**: Valve Steam Deck Docking Station.
*   **Output Path**: **Direct ALSA** (`aplay` to `hw:0,8`).
*   **Behavior**:
    *   Hardcoded detection of known Loopback/HDMI sinks.
    *   Uses direct `aplay` passthrough to the hardware to avoid PipeWire scheduling jitter/stuttering on the Deck.
    *   Manages IEC958 Non-Audio bit configuration and profile disabling for exclusive hardware access.
    *   Aggressive cleanup/recovery logic (killing children, resetting PulseAudio profiles).

### 2. `scripts/launch_live_laptop.sh`
*   **Target Hardware**: Generic Linux desktop/laptop.
*   **Output Path**: **PipeWire Native** (in-graph playback stream).
*   **Behavior**:
    *   Dynamic scanning for PCI sound cards and `hdmi-stereo` sinks.
    *   Low-latency defaults (`64` frames) for responsive desktop usage.
    *   Standard `pactl` profile switching logic.

## Latency Considerations
*   **Buffering**: The RingBuffer must be large enough to absorb jitter between the RT thread and the Encoder thread, but small enough to minimize AV sync issues. 
*   **Target**: < 50ms total system latency.

## Testing Strategy
*   **Encoder Tests**: `tests/encoder_tests.rs` validates throughput, restart/shutdown behavior, IEC61937 preamble presence, and shutdown under output backpressure.
*   **PipeWire Client Tests**: `tests/pipewire_client_tests.rs` validates safe audio buffer parsing, playback target resolution, and stdout loop shutdown semantics.
*   **Local End-to-End Script**: `scripts/test_local_pipeline.sh` validates encoder output and graph wiring with a null sink plus monitor capture.
*   **Native End-to-End Script**: `scripts/test_pipewire_pipeline.sh` validates strict IEC61937 presence from the native `pw-ac3-live-output` stream.
*   **CI**: GitHub Actions validates the build, formatting, and unit tests on every commit.
