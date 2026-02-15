# Architecture & Design

## Overview
`pw-ac3-live` is designed to bridge the gap between modern multi-channel audio sources (games, media players) and legacy or restricted hardware sinks (HDMI ARC/SPDIF) on Linux/PipeWire systems.

## Data Flow Pipeline

```mermaid
graph LR
    A[PipeWire Source] -->|6ch f32 PCM| B(Capture Thread)
    B -->|Lock-free RingBuffer| C(Encoder Thread)
    C -->|AC-3 Encoded Bytes| D(Playback Thread)
    D -->|IEC61937 Stream| E[ALSA HDMI Sink]
```

## Threading Model

To ensure glitch-free audio, we strictly separate real-time (RT) tasks from compute-intensive or blocking tasks.

### 1. Capture Thread (RT-Safe)
*   **Context**: PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
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

### 4. Playback Thread (RT-Safe)
*   **Context**: PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
*   **Constraints**: Same as Capture Thread.
*   **Responsibility**:
    *   Read encoded IEC 61937 frames from `OutputRingBuffer`.
    *   Write to the PipeWire buffer for the HDMI sink.
    *   Handle underruns by writing zero-padding (silence) to maintain clock sync.
    *   Keep PipeWire stream listener/callback handles alive for the whole loop lifetime.

## Interaction with PipeWire
*   **Virtual Sink**: The application creates `pw-ac3-live-input` (Audio/Sink, 6ch @ 48kHz).
*   **Virtual Source**: In native mode it creates `pw-ac3-live-output` (Audio/Source, 2ch S16LE carrying IEC61937 payload).
*   **Playback Targeting**: Output can be routed by explicit `--target` (node name or numeric object ID), or emitted to stdout in `--stdout` mode.

## Latency Considerations
*   **Buffering**: The RingBuffer must be large enough to absorb jitter between the RT thread and the Encoder thread, but small enough to minimize AV sync issues. 
*   **Target**: < 50ms total system latency.

## Testing Strategy
*   **Encoder Tests**: `tests/encoder_tests.rs` validates throughput, restart/shutdown behavior, IEC61937 preamble presence, and shutdown under output backpressure.
*   **PipeWire Client Tests**: `tests/pipewire_client_tests.rs` validates safe audio buffer parsing, playback target resolution, and stdout loop shutdown semantics.
*   **Local End-to-End Script**: `scripts/test_local_pipeline.sh` validates encoder output and graph wiring with a null sink plus monitor capture.
*   **Native End-to-End Script**: `scripts/test_pipewire_pipeline.sh` validates strict IEC61937 presence from the native `pw-ac3-live-output` stream.
*   **CI**: GitHub Actions validates the build, formatting, and unit tests on every commit.
