#!/bin/bash
# CI Integration Test: verify --help exits cleanly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[CI-HELP]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

log "Building pw-ac3-live..."
cargo build --release 2>&1

log "Running --help..."
OUTPUT=$(./target/release/pw-ac3-live --help 2>&1)
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    error "--help exited with code $EXIT_CODE"
    echo "$OUTPUT"
    exit 1
fi

# Verify it contains expected content
if ! echo "$OUTPUT" | grep -q "AC-3"; then
    error "--help output doesn't mention AC-3"
    echo "$OUTPUT"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q -- "--stdout"; then
    error "--help output doesn't mention --stdout flag"
    echo "$OUTPUT"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q -- "--target"; then
    error "--help output doesn't mention --target flag"
    echo "$OUTPUT"
    exit 1
fi

log "✓ --help exits cleanly and shows expected flags"
