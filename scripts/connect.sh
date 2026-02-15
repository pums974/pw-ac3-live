#!/bin/bash
set -e

# CLI to connect pw-ac3-live-output to a target sink/node
# Usage: ./connect.sh [target-node-name-pattern]

TARGET_PATTERN="$1"

if [ -z "$TARGET_PATTERN" ]; then
    echo "Usage: $0 <target-node-name>"
    echo "Example: $0 alsa_output"
    exit 1
fi

echo "Searching for pw-ac3-live-output ports..."
OUTPUT_PORTS=$(pw-link -o | grep "pw-ac3-live-output")

if [ -z "$OUTPUT_PORTS" ]; then
    echo "Error: pw-ac3-live-output node not found or has no output ports."
    echo "Is the daemon running?"
    exit 1
fi

echo "Found output ports:"
echo "$OUTPUT_PORTS"

echo "Searching for target input ports matching '$TARGET_PATTERN'..."
TARGET_PORTS=$(pw-link -i | grep "$TARGET_PATTERN")

if [ -z "$TARGET_PORTS" ]; then
    echo "Error: No input ports found matching pattern '$TARGET_PATTERN'."
    exit 1
fi

echo "Found target ports:"
echo "$TARGET_PORTS"

# Strategy: Link output_1 -> playback_FL (or first port), output_2 -> playback_FR (or second port)
# We need to sort them to ensure consistent mapping.

O_PORTS=($(echo "$OUTPUT_PORTS" | sort))
T_PORTS=($(echo "$TARGET_PORTS" | sort))

NUM_O=${#O_PORTS[@]}
NUM_T=${#T_PORTS[@]}

echo "Linking $NUM_O output ports to $NUM_T target ports..."

LIMIT=$NUM_O
if [ $NUM_T -lt $NUM_O ]; then
    LIMIT=$NUM_T
fi

for ((i=0; i<LIMIT; i++)); do
    SRC="${O_PORTS[$i]}"
    DST="${T_PORTS[$i]}"
    echo "Connecting $SRC -> $DST"
    pw-link "$SRC" "$DST" || echo "Failed to link $SRC -> $DST (maybe already linked?)"
done

echo "Done."
