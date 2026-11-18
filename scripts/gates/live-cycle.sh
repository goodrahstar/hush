#!/bin/bash
# Live: podcast plays 15 s (Hush switches to the echo-cancelled mic), then stops; within 30 s Hush must be
# back on a running plain mic. At no point may Hush be on with no mic for more than 6 s in a row.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; LOG="$HOME/Library/Logs/Hush.log"
pgrep -x Hush >/dev/null || { echo "Hush is not running"; exit 1; }
for _ in $(seq 1 40); do tail -1 "$LOG" | grep -qE "^[0-9:]+ (quiet|listening) [a-z]+ \\|.* mic on\\(" && break; sleep 1; done
start=$(wc -l < "$LOG")
qt() { osascript -e "tell application \"QuickTime Player\" to $1"; }
osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$ROOT/.build/gate-fixtures/podcast.aiff\"" >/dev/null
sleep 1; qt "set current time of document 1 to 0"; qt "play document 1"
sleep 15; qt "pause document 1"; sleep 30
new=$(tail -n +"$((start + 1))" "$LOG")
echo "$new" | grep -E "switching|mic started|mic error|no mic|pause sent|stopped" || true
echo "$new" | grep -q "echo-cancelled mic started" || { echo "never started the echo-cancelled mic"; exit 1; }
echo "$new" | grep -q "plain mic started" || { echo "never went back to the plain mic"; exit 1; }
echo "$new" | tail -1 | grep -q " mic on(" || { echo "last status has no plain mic running: $(echo "$new" | tail -1 | cut -c1-120)"; exit 1; }
gap=$(echo "$new" | awk '/^[0-9:]+ (quiet|listening|paused|ducked) / { if ($0 ~ / mic off$/) { run++; if (run>max) max=run } else run=0 } END { print max+0 }')
echo "longest stretch with no mic: ${gap} s"
[ "$gap" -le 6 ] || { echo "mic was down too long"; exit 1; }
audit=$(echo "$new" | python3 "$ROOT/scripts/gates/pause-audit.py"); echo "$audit"
echo "$audit" | grep -q "FALSE_PAUSES=0" || { echo "FALSE PAUSE"; exit 1; }
echo LIVE_CYCLE_OK
