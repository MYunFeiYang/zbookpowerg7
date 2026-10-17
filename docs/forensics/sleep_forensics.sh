#!/bin/bash
# Sleep-death forensics logger (root LaunchDaemon, com.zbook.sleepforensics)
# Purpose: persist log stream to disk so a hard-power-off after a sleep hang
# still leaves the pre-hang window readable. Marker lines every 60s let us
# pinpoint when userspace froze during the sleep transition.
DIR=/Users/Shared/SleepForensics
mkdir -p "$DIR"
LOG="$DIR/forensics-$(date +%Y%m%d-%H%M%S).log"
echo "=== start $(date '+%F %T') pid $$ ===" >> "$LOG"
# prune: keep newest 5 files
ls -t "$DIR"/forensics-*.log 2>/dev/null | tail -n +6 | xargs -I{} rm -f "{}"
( while :; do echo "=== marker $(date '+%F %T') ===" >> "$LOG"; sleep 60; done ) &
MARKPID=$!
trap 'kill $MARKPID 2>/dev/null' EXIT
log stream --style compact --level info \
  --predicate '(messageType >= 16) OR (eventMessage CONTAINS[c] "sleep") OR (eventMessage CONTAINS[c] "wake") OR (eventMessage CONTAINS[c] "nvme") OR (eventMessage CONTAINS[c] "IOPM") OR (process == "bluetoothd")' \
  >> "$LOG" 2>&1
echo "=== log stream exited $(date '+%F %T') ===" >> "$LOG"
