# Current Steam Deck State Analysis

## 1. Working Parameters (Default Configuration)

The system is currently running with the default parameters defined in `scripts/launch_live.sh`, which override the binary's internal defaults. These settings prioritize stability over latency, resulting in the "very high latency" observed.

| Parameter | Value | Source | Impact on Latency |
| :--- | :--- | :--- | :--- |
| **Input Buffer Size** | `6144` frames | `launch_live.sh` (matches default) | **128 ms** (at 48kHz). Primary source of capture latency. |
| **Output Buffer Size** | `8192` frames | `launch_live.sh` (matches default) | **~170 ms**. Output buffering. |
| **Node Latency** | `1536/48000` | `launch_live.sh` (matches default 32ms) | **32 ms**. PipeWire processing quantum. |
| **FFmpeg Chunk Frames** | `1536` | `launch_live.sh` | matches AC-3 frame size (32ms). |
| **FFmpeg Thread Queue** | `32` chunks | `launch_live.sh` | **Up to ~1 sec** (32 * 32ms) if the queue fills up. |
| **PulseAudio Latency** | `60` ms | `launch_live.sh` (`export PULSE_LATENCY_MSEC`) | **60 ms**. Additional compatibility buffering. |

**Total Estimated Latency Stack:** 128ms (Input) + 32ms (Node) + 32-1000ms (Encoder Queue) + ~170ms (Output) + 60ms (Pulse) ≈ **400ms - 1.4s** depending on queue fullness.

## 2. Audio System State (Deduced from output.logs)

The logs reveal a specific "fallback" behavior that allows the system to work despite complex routing issues.

*   **Sink Selection**:
    *   The script initially selects the **Loopback Sink** (`alsa_loopback_device...`).
    *   **CRITICAL**: It detects that the physical HDMI sink is "hidden/busy" (likely locked by another process or the loopback itself).
*   **Direct ALSA Fallback**:
    *   The script triggers `PW_AC3_DIRECT_ALSA_FALLBACK=1`.
    *   It bypasses PipeWire/PulseAudio for the final output stage and uses `aplay` directly to the hardware device.
    *   **Hardware Device**: `hw:0,8` (Card 0, Device 8).
    *   **Format**: It forces IEC958 "Non-Audio" bit setting (`iecset`) to ensure the receiver detects data, not PCM audio.
*   **Routing**:
    *   Apps -> `pw-ac3-live-input` (Virtual Sink) -> **Encoder** -> `aplay` -> `hw:0,8` (HDMI).
    *   The standard `pw-ac3-live-output` node is likely not being linked normally because `aplay` is taking exclusive control of the hardware.

## 3. Analysis of Diagnostic Output

Analysis of the `working_state` logs confirms the following:

1.  **Physical Sink Hidden**: `pactl_sinks.txt` **does not list the physical HDMI sink**. Only the `alsa_loopback_device` and `pw-ac3-live-input` are visible. This confirms that the exclusive access or configuration of the loopback device is preventing PipeWire from exposing the hardware HDMI sink as a standard node.
2.  **Fallback Justified**: Because the physical sink is missing from the graph, the script's `DIRECT_ALSA_FALLBACK` mechanism is actively saving the session by bypassing PipeWire output and writing directly to the hardware.
3.  **Hardware Target Identified**: `eld_info.txt` confirms the connected display is an **LG TV SSCR2** (connected to `eld#0.2` on Card 0).
    *   **Capabilities**: It explicitly supports **AC-3**, **E-AC-3**, **DTS**, and **DTS-HD**.
    *   **Connection**: `monitor_present` is true on this port.
4.  **Routing Success**: `pactl_inputs.txt` shows that applications (Firefox playing Spotify and YouTube) are correctly routed to the `pw-ac3-live-input` (ID 789).
5.  **Device Mismatch/Confusion**:
    *   `eld_info` shows the active monitor on `eld#0.2`.
    *   The script logs showed a conflict between "ELD detected (3)" and "Profile derived (8)".
    *   `aplay -L` lists `hdmi:CARD=Generic,DEV=2` for the LG TV.
    *   The mismatch in device numbering (2 vs 3 vs 8) suggests that while the forced fallback works, the explicit device selection logic might be fragile.

**Conclusion**: The system is functional but relies on the "Direct ALSA" safety net. The high latency is purely a function of the buffer settings (confirmed default) and not a routing error.

## 4. Emergency Manual Restoration (Guaranteed Working State)

If the script logic ever fails (e.g., due to PipeWire updates), you can **guarantee** the return to this working state by manually forcing the hardware into the correct mode using these exact commands captured from the working system.

### Step 1: Force HDMI to "Non-Audio" Mode (Critical)
This tells the receiver that the data is **NOT** PCM audio (which would blast white noise), but compressed data (AC-3).
*   **Target**: Card 0 (`hw:0`), Device 8 (`pcm=8`), Index 2 (matches `IEC958 Playback Default,index=2` in amixer).
*   **Value**: `0x06,0x00,0x00,0x02` (Consumer, Non-Audio, 48kHz).

```bash
# Unlock the device if busy (kill existing players)
pkill -9 aplay || true
pkill -9 pw-ac3-live || true

# Set the status bits for "Non-Audio" (AC-3/DTS)
amixer -c 0 cset iface=MIXER,name='IEC958 Playback Default',index=2 0x06,0x00,0x00,0x02
```

### Step 2: Manually Run the Encoder Pipeline
Use the exact `aplay` parameters captured from the working state (`--buffer-time=200000` = 200ms buffer).

```bash
# Capture from PipeWire manually (or use the binary) and pipe to aplay
# This bypasses all script logic and talks directly to hardware.
/path/to/pw-ac3-live --stdout | \
aplay -D hw:0,8 \
    --disable-resample \
    --disable-format \
    --disable-channels \
    --disable-softvol \
    -v -t raw \
    -f S16_LE \
    -r 48000 \
    -c 2 \
    --buffer-time=200000 \
    --period-time=20000
```