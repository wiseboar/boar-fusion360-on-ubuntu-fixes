#!/bin/bash
# Wrapper that runs str0g's Fusion 360 installer with logging and the
# system X display available to Wine subprocesses.
#
# Logs go to INSTALL/install.log (full) and INSTALL/install.last.log (last run).
#
# Usage:
#   ./run-install.sh           # full install
#   ./run-install.sh <action>  # pass through to fusion_installer.sh

set -u
cd "$(dirname "$0")"

: "${DISPLAY:=:1}"
export DISPLAY
export XAUTHORITY="${XAUTHORITY:-/run/user/$(id -u)/gdm/Xauthority}"
# Wine noise reduction
export WINEDEBUG="${WINEDEBUG:-err-ole,fixme-all,-winediag}"

LOG=./install.log
LAST=./install.last.log
: > "$LAST"

{
  echo "=== run-install.sh $(date -Is) ==="
  echo "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY"
  echo "wine: $(wine --version 2>&1)"
  echo "winetricks (system): $(winetricks --version 2>&1 | head -1 || echo 'not in PATH')"
  echo "args: $*"
  echo "---"
} | tee -a "$LOG" "$LAST"

./fusion_installer.sh "$@" 2>&1 | tee -a "$LOG" "$LAST"
rc=${PIPESTATUS[0]}

echo "=== exit $rc at $(date -Is) ===" | tee -a "$LOG" "$LAST"
exit "$rc"
