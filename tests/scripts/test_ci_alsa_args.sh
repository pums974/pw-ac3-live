#!/bin/bash
# CI Integration Test: validate mandatory CLI args for --alsa-direct
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[CI-ALSA-ARGS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

expect_fail_contains() {
  local expected="$1"
  shift

  set +e
  local output
  output="$("$@" 2>&1)"
  local exit_code=$?
  set -e

  if [ "$exit_code" -eq 0 ]; then
    error "Command unexpectedly succeeded: $*"
    echo "$output"
    exit 1
  fi

  if ! echo "$output" | grep -q -- "$expected"; then
    error "Expected error message not found: $expected"
    echo "$output"
    exit 1
  fi
}

log "Building pw-ac3-live..."
cargo build --release 2>&1

BIN=./target/release/pw-ac3-live

log "Checking: missing --target"
expect_fail_contains "--alsa-direct requires --target <alsa-device>" \
  "$BIN" --alsa-direct --alsa-iec-card 0 --alsa-iec-index 2

log "Checking: missing --alsa-iec-card"
expect_fail_contains "--alsa-direct requires --alsa-iec-card <card-id>" \
  "$BIN" --alsa-direct --target hw:0,8 --alsa-iec-index 2

log "Checking: missing --alsa-iec-index"
expect_fail_contains "--alsa-direct requires --alsa-iec-index <iec-index>" \
  "$BIN" --alsa-direct --target hw:0,8 --alsa-iec-card 0

log "Checking: empty --target value"
expect_fail_contains "--alsa-direct requires --target <alsa-device>" \
  "$BIN" --alsa-direct --target "   " --alsa-iec-card 0 --alsa-iec-index 2

log "Checking: empty --alsa-iec-card value"
expect_fail_contains "--alsa-direct requires --alsa-iec-card <card-id>" \
  "$BIN" --alsa-direct --target hw:0,8 --alsa-iec-card "   " --alsa-iec-index 2

log "Checking: empty --alsa-iec-index value"
expect_fail_contains "--alsa-direct requires --alsa-iec-index <iec-index>" \
  "$BIN" --alsa-direct --target hw:0,8 --alsa-iec-card 0 --alsa-iec-index "   "

log "Checking: --stdout conflicts with --alsa-direct"
expect_fail_contains "cannot be used with '--stdout'" \
  "$BIN" --alsa-direct --stdout --target hw:0,8 --alsa-iec-card 0 --alsa-iec-index 2

log "✓ Mandatory ALSA CLI argument checks passed"
