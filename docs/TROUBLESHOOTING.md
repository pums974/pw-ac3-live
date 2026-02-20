# Troubleshooting Guide

This guide covers common issues encountered when using `pw-ac3-live` and the Direct ALSA path.

---

## 0. Run Built-In Validators First
Before deep debugging, run these scripts in order to quickly narrow down whether the problem is environment setup, live runtime state, or perceived audio behavior.

### Environment validation (static setup)
Checks required tools, PipeWire cards/profiles, ALSA endpoints, and HDMI/ELD capabilities.
```bash
./scripts/validate_env.sh
```

### Runtime validation (live pipeline state)
Checks process status, PipeWire links/nodes, sink routing, active ALSA streams, and IEC958 status while the pipeline is running.
```bash
./scripts/validate_runtime.sh
```

### Interactive audio validation (human hearing checks)
Plays controlled test signals and asks you to confirm audibility, channel mapping, and rough latency perception.
```bash
./scripts/validate_audio.sh
```

---

## 1. Loud Noise / Static (The "Zombie State")
**Symptoms:** You hear loud white noise or static instead of audio.
**Cause:** The HDMI audio driver is in a "Zombie State" or the sink is configured incorrectly.

### Fix 1: Check Volume (Critical)
The HDMI sink volume **MUST be 100% (0dB)**. Even 99% volume modifies the bits, causing the AC-3 stream to be decoded as noise.
```bash
# Set ALL related sinks to 100%
pactl set-sink-volume <YOUR_HDMI_SINK> 100%
pactl set-sink-volume pw-ac3-live-input 100%
```

### Fix 2: Force "Non-Audio" Bit (Direct ALSA / Steam Deck)
If using the **Direct ALSA** path, the IEC958 status bits must be set to "Non-Audio" so the receiver knows it's a data stream (AC-3), not PCM audio.
Run this for your card (e.g., card 0):
```bash
# Try indices 0-3 to be safe
iecset -c 0 -n 0 audio off rate 48000
iecset -c 0 -n 1 audio off rate 48000
iecset -c 0 -n 2 audio off rate 48000
iecset -c 0 -n 3 audio off rate 48000
```
*Note: `iecset` is part of `alsa-utils`.*

### Fix 3: Check HDMI Profile (PipeWire Native)
Ensure your card is in **Stereo** mode, NOT Surround.
```bash
pactl set-card-profile <CARD_NAME> output:hdmi-stereo
```

---

## 2. No Audio / Silence
**Symptoms:** Everything looks like it's running, but there is no sound.

### Checklist
1.  **Is the App Playing?**
    Check that your music/video player is actually outputting audio and is routed to **"AC-3 Encoder Input"**.
    ```bash
    pw-link -l | grep pw-ac3-live-input
    ```

2.  **Is the Encoder Linked?** (PipeWire Native only)
    Check that `pw-ac3-live-output` is linked to your physical HDMI sink.
    ```bash
    pw-link -l | grep pw-ac3-live-output
    ```

3.  **Is the Sink Muted?**
    Check `wpctl status` for any `[MUTED]` tags on your HDMI sink or the encoder input.

4.  **Is Direct ALSA blocked?**
    If using Path B, check `aplay` logs for "Device or resource busy".
    ```bash
    cat /tmp/aplay.log
    ```

---

## 3. Stuttering / Choppy Audio (Steam Deck)
**Symptoms:** Audio plays but cuts out frequently or sounds robotic.
**Cause:** PipeWire's ALSA plugin scheduling jitter or buffer underruns.

### Solution 1: Use Direct ALSA
The native PipeWire path is known to stutter on Steam Deck. Use **Path B (Direct ALSA)** as described in [Manual Setup](MANUAL_SETUP.md).

### Solution 2: Tune Buffers
Increase the output buffer size to absorb scheduling jitter.
---

## 4. Channels are Wrong (Stereo Only)
**Symptoms:** You hear sound, but Rear/Center channels are mixed into Front Left/Right.
**Cause:** The source application is sending Stereo, or the receiver is in "Stereo" mode.

### Verification
Run the channel test script to confirm if the **encoder** is working correctly:
```bash
./scripts/validate_audio.sh
```
- If this test plays correctly on all speakers, the encoder pipeline is **fine**.
- The issue is likely your source app (e.g., Browser) or Windows game running in Proton not configured for 5.1.

### Receiver Mode
Ensure your AVR/Soundbar is in **"Direct"**, **"Straight"**, or **"Dolby Digital"** mode.
Avoid modes named **"Stereo"**, **"2ch"**, or **"Multi-Channel Stereo"**.

---

## 5. Emergency Reset
If audio is completely stuck:
```bash
# 1. Kill everything
pkill -INT -f pw-ac3-live
pkill -INT -f aplay

# 2. Reset ALSA state (optional but helpful)
alsactl restore

# 3. Unplug HDMI cable for 5 seconds and reconnect to force strict handshake.
```
