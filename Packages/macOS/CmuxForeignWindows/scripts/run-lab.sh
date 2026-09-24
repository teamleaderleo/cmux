#!/usr/bin/env bash
# One command to iterate on the lab: quit the running lab and its Claude
# panes, rebuild and re-sign the app, and open it again with logging.
#
#   scripts/run-lab.sh [--profiles work,personal] [--sign "<identity>"]
#
# The log goes to /tmp/fwlab.log. Profiles keep their sign-ins across runs.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES="work,personal"
SIGN_IDENTITY="SmolRunner Local Release Signing"
LOG=/tmp/fwlab.log
BUNDLE_ID="com.cmuxterm.foreignwindowlab"
PROFILE_ROOT="$HOME/Library/Application Support/cmux/external-apps/claude/"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles) PROFILES="$2"; shift 2 ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Quit the lab politely so it hands claude:// back to Claude and closes its
# panes' Claude processes itself.
if pgrep -f "ForeignWindowLab.app/Contents/MacOS/ForeignWindowLab" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -f "ForeignWindowLab.app/Contents/MacOS/ForeignWindowLab" >/dev/null || break
    sleep 0.25
  done
  pkill -f "ForeignWindowLab.app/Contents/MacOS/ForeignWindowLab" 2>/dev/null || true
fi

# Close any lab-profile Claude copies still running (only ones launched with a
# cmux profile dir; the user's own Claude is never touched).
if pgrep -f "Claude --user-data-dir=$PROFILE_ROOT" >/dev/null; then
  pkill -f "Claude --user-data-dir=$PROFILE_ROOT" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "Claude --user-data-dir=$PROFILE_ROOT" >/dev/null || break
    sleep 0.25
  done
fi

"$PACKAGE_DIR/scripts/build-lab-app.sh" --sign "$SIGN_IDENTITY"

: > "$LOG"
open -n --stdout "$LOG" --stderr "$LOG" "$PACKAGE_DIR/.build/ForeignWindowLab.app" \
  --args --profiles "$PROFILES" --verbose
echo "Lab running. Log: $LOG"
