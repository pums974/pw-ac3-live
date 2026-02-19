#!/bin/bash
set -e

# CLI to connect pw-ac3-live-output to a target sink/node
# Usage: ./connect.sh [target-node-name-pattern]

TARGET_PATTERN="$1"
EXCLUSIVE_HDMI="${PW_AC3_EXCLUSIVE_HDMI:-1}"
ALLOW_SUBSTRING_FALLBACK="${PW_AC3_CONNECT_ALLOW_FALLBACK:-0}"

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
# Prefer exact node-name match (<node>:<port>) to avoid catching loopback aliases.
TARGET_PORTS=$(pw-link -i | awk -v node="$TARGET_PATTERN" '
    {
        split($1, parts, ":");
        if (parts[1] == node) {
            print $1;
            found = 1;
        }
    }
    END {
        if (!found) {
            # no-op; shell fallback below handles substring mode
        }
    }
')

# Backward-compatible fallback: substring match when exact node is absent.
if [ -z "$TARGET_PORTS" ]; then
  if [ "$ALLOW_SUBSTRING_FALLBACK" = "1" ]; then
    TARGET_PORTS=$(pw-link -i | grep "$TARGET_PATTERN" || true)
  fi
fi

if [ -z "$TARGET_PORTS" ]; then
  echo "Error: No input ports found for node '$TARGET_PATTERN'."
  echo "Available input nodes:"
  pw-link -i | awk -F: '{print $1}' | sort -u
  echo "Tip: set PW_AC3_CONNECT_ALLOW_FALLBACK=1 to enable substring matching."
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

SUCCESS_COUNT=0
FAILED_COUNT=0
PERMISSION_DENIED_COUNT=0

if [ "$EXCLUSIVE_HDMI" = "1" ]; then
  echo "Enforcing exclusive HDMI links (pre-emptively disconnecting other sources)..."
  while IFS= read -r link_line; do
    case "$link_line" in
      *" -> "*)
        SRC="${link_line%% -> *}"
        DST="${link_line##* -> }"
        ;;
      *)
        continue
        ;;
    esac

    for target in "${T_PORTS[@]}"; do
      if [ "$DST" = "$target" ] && [[ "$SRC" != pw-ac3-live-output:* ]]; then
        echo "Disconnecting rogue link $SRC -> $DST"
        pw-link -d "$SRC" "$DST" || true
      fi
    done
  done < <(pw-link -l)
fi

for ((i = 0; i < LIMIT; i++)); do
  SRC="${O_PORTS[$i]}"
  DST="${T_PORTS[$i]}"
  echo "Connecting $SRC -> $DST"
  LINK_OUTPUT="$(pw-link "$SRC" "$DST" 2>&1)" || LINK_RC=$?
  LINK_RC=${LINK_RC:-0}
  if [ "$LINK_RC" -eq 0 ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    if echo "$LINK_OUTPUT" | grep -Eiq "(file exists|already linked|existe)"; then
      echo "$LINK_OUTPUT"
      echo "Link already exists for $SRC -> $DST."
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "$LINK_OUTPUT"
      echo "Failed to link $SRC -> $DST."
      FAILED_COUNT=$((FAILED_COUNT + 1))
      if echo "$LINK_OUTPUT" | grep -Eiq "operation not permitted|permission denied|not permitted"; then
        PERMISSION_DENIED_COUNT=$((PERMISSION_DENIED_COUNT + 1))
      fi
    fi
  fi
  unset LINK_RC
done

if [ "$EXCLUSIVE_HDMI" = "1" ]; then
  echo "Ensuring pw-ac3-live-output is linked only to target HDMI ports..."
  while IFS= read -r link_line; do
    case "$link_line" in
      *" -> "*)
        SRC="${link_line%% -> *}"
        DST="${link_line##* -> }"
        ;;
      *)
        continue
        ;;
    esac

    if [[ "$SRC" == pw-ac3-live-output:* ]]; then
      keep=0
      for target in "${T_PORTS[@]}"; do
        if [ "$DST" = "$target" ]; then
          keep=1
          break
        fi
      done
      if [ "$keep" -eq 0 ]; then
        echo "Disconnecting extra pw-ac3-live route $SRC -> $DST"
        pw-link -d "$SRC" "$DST" || true
      fi
    fi
  done < <(pw-link -l)
fi

if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$FAILED_COUNT" -gt 0 ] && [ "$PERMISSION_DENIED_COUNT" -gt 0 ]; then
  echo "Error: All link attempts were denied by policy/permissions."
  exit 13
fi

echo "Done."
