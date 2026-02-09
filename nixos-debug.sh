#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

ORIG=/root/installer/bootstrap-kexec.sh
if [ ! -f "$ORIG" ]; then
  echo "Missing $ORIG"
  exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
WORKDIR="/root/kexec-debug-$TS"
LOG="/root/installer/bootstrap-kexec.debug.log"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

export KEEP_WORKDIR=1
export KEXEC_WORKDIR="$WORKDIR"
export KEXEC_DEBUG_RUN=1

echo "Running $ORIG (workdir: $WORKDIR)"
bash "$ORIG" |& tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "Exit code: $rc"

echo "Saved log: $LOG"
echo "Workdir: $WORKDIR"
echo "If it fails, send: $LOG and 'ls -la $WORKDIR'"
exit "$rc"
