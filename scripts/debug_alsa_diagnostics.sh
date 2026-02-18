#!/bin/bash
echo "=== aplay -l ==="
aplay -l || echo "aplay not found"
echo ""
echo "=== pactl list sinks (full) ==="
pactl list sinks
echo ""
echo "=== pw-top (snapshot) ==="
# changing batch mode for pw-top if supported, or just timeout
timeout 2s pw-top -b 1 || echo "pw-top failed"
