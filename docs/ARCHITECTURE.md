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
    *   NO allocations (malloc/free).
    *   NO mutex locking.
    *   NO syscalls (e.g., I/O).
*   **Responsibility**: 
    *   Deinterleave input audio if necessary.
    *   Write raw samples to the `InputRingBuffer`.

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

### 4. Playback Thread (RT-Safe)
*   **Context**: PipeWire `process` callback.
*   **Priority**: Real-time (SCHED_FIFO).
*   **Constraints**: Same as Capture Thread.
*   **Responsibility**:
    *   Read encoded IEC 61937 frames from `OutputRingBuffer`.
    *   Write to the PipeWire buffer for the HDMI sink.
    *   Handle underruns by writing zero-padding (silence) to maintain clock sync.

## Interaction with PipeWire
*   **Virtual Sink**: The application creates a virtual sink node that games/apps can link to.
*   **Passthrough**: The application connects its output node directly to the hardware HDMI/SPDIF node, negotiating the `audio/x-ac3` or `audio/x-iec958-data` format.

## Latency Considerations
*   **Buffering**: The RingBuffer must be large enough to absorb jitter between the RT thread and the Encoder thread, but small enough to minimize AV sync issues. 
*   **Target**: < 50ms total system latency.

## Testing Strategy
*   **Unit Tests**: The `encoder` module is tested in isolation (`tests/encoder_tests.rs`) by mocking input data and verifying MP4/AC-3 output presence from the FFmpeg subprocess.
*   **Integration/System Tests**: Due to the dependency on a running PipeWire daemon and hardware sinks, full system verification is currently manual (see `README.md`).
*   **CI**: GitHub Actions validates the build, formatting, and unit tests on every commit.
