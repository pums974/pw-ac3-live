---
name: pw_operator
description: Standardized procedures for running and debugging pw-ac3-live.
---

# PipeWire Operator Skill

This skill documents the approved methods for launching and debugging the `pw-ac3-live` application.

## Launching the Application

### 1. Steam Deck (Production Target)
Due to hardware dependencies (Direct ALSA `hw:0,8`), code must be deployed to the Steam Deck to run.

**1. Package & Deploy:**
```bash
./scripts/package_steam_deck.sh
scp -r dist/pw-ac3-live-steamdeck-0.1.0 steamdeck:/home/deck/Downloads/
```

**2. Run via SSH:**
**CRITICAL**: Use `-t` to allocate a pseudo-terminal. This ensures signals (Ctrl+C) are correctly propagated to stop the application cleanly.
```bash
ssh -t -- steamdeck "/home/deck/Downloads/pw-ac3-live-steamdeck-0.1.0/scripts/launch_live_steamdeck.sh"
```

**Notes**:
- Targets Direct ALSA hardware (`hw:0,8`).
- Bypasses PipeWire graph for output.
- Sets specific ALSA parameters for stability.

### 2. Laptop / Development (Testing Target)
**Script**: `./scripts/launch_live_laptop.sh`
**Usage**:
```bash
./scripts/launch_live_laptop.sh
```
**Notes**:
- Targets PipeWire node.
- Useful for logic verification without specific hardware.

## Debugging

### 1. Logging
The application uses `env_logger`. Control verbosity with `RUST_LOG`.
```bash
RUST_LOG=debug ./scripts/launch_live_laptop.sh
RUST_LOG=trace ./scripts/launch_live_laptop.sh # Very verbose!
```

### 2. PipeWire Tools
- `pw-cli info <id>`: Inspect node properties.
- `pw-dot`: Visualize the graph (install `graphviz` to view `.dot` files).
- `pw-top`: Monitor real-time performance and quantum usage.
