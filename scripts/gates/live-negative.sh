#!/bin/bash
# Live: the installed app is on, a podcast plays on the speakers for 35 s and nobody talks.
# Pass = Hush recognised talk, switched to the echo-cancelled mic, kept logging every second, never paused,
# and QuickTime is still playing at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; LOG="$HOME/Library/Logs/Hush.log"
pgrep -x Hush >/dev/null || { echo "Hush is not running"; exit 1; }
[ "$(defaults read com.rahulkumar.hush enabled 2>/dev/null || echo 1)" = 1 ] || { echo "Hush is switched off"; exit 1; }
# Start from the plain mic so the switch itself is observed (Hush keeps echo cancellation 15 s after talk ends).
for _ in $(seq 1 40); do tail -1 "$LOG" | grep -qE "^[0-9:]+ (quiet|listening) [a-z]+ \|" && break; sleep 1; done
start=$(wc -l < "$LOG")
qt() { osascript -e "tell application \"QuickTime Player\" to $1"; }
osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$ROOT/.build/gate-fixtures/podcast.aiff\"" >/dev/null
sleep 1; qt "set current time of document 1 to 0"; qt "play document 1"
sleep 35
playing=$(qt 'get playing of document 1'); qt "pause document 1"
new=$(tail -n +"$((start + 1))" "$LOG")
echo "$new" | grep -E "switching|mic started|pause sent|resume|error" || true
status=$(echo "$new" | grep -cE "^[0-9:]+ (quiet|listening|paused|ducked|off) " || true)
echo "status lines: $status · quicktime playing at end: $playing"
echo "$new" | grep -q "switching to the echo-cancelled mic" || { echo "never switched to echo cancellation"; exit 1; }
echo "$new" | grep -q "echo-cancelled mic started" || { echo "echo-cancelled mic did not start"; exit 1; }
echo "$new" | grep -q "listening talk ec" || { echo "never listened to talk with echo cancellation"; exit 1; }
audit=$(echo "$new" | python3 "$ROOT/scripts/gates/pause-audit.py"); echo "$audit"
echo "$audit" | grep -q "FALSE_PAUSES=0" || { echo "FALSE PAUSE"; exit 1; }
[ "$status" -ge 30 ] || { echo "main loop stalled"; exit 1; }
[ "$playing" = true ] || { echo "QuickTime stopped"; exit 1; }
echo LIVE_NEGATIVE_OK
