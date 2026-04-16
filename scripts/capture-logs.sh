#!/usr/bin/env bash
#
# capture-logs.sh
#
# Streams KV-TextSniper's os.Logger output into logs/kvts.log inside the
# project folder. The assistant can read that file directly — no copy-paste
# needed.
#
# Usage:
#   1. ./scripts/capture-logs.sh           (starts streaming, Ctrl+C to stop)
#   2. in Xcode: ⌘R to relaunch the app, then reproduce the bug
#   3. back in Terminal: Ctrl+C
#   4. tell me "done" — I'll read logs/kvts.log
#

set -euo pipefail

# Resolve the directory this script lives in, regardless of where it's called from.
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd )"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/kvts.log"

mkdir -p "$LOG_DIR"

# Truncate previous run so the assistant only sees the current reproduction.
: > "$LOG_FILE"

echo "Streaming KV-TextSniper logs to: $LOG_FILE"
echo "Now reproduce the bug in the app. Press Ctrl+C when done."
echo

# `log stream` writes to stdout; `tee` also echoes to the terminal so the
# user can see activity live. `--level debug` includes all levels.
log stream \
    --predicate 'subsystem == "com.viacheslav.KV-TextSniper"' \
    --level debug \
    --style compact \
    | tee "$LOG_FILE"
