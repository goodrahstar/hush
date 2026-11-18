#!/bin/bash
# Plays the podcast fixture in QuickTime, then pauses and resumes it through Hush's MediaControl,
# checking QuickTime's own "playing" state each time. Leaves QuickTime paused.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; BIN="$ROOT/.build/release/Hush"
qt() { osascript -e "tell application \"QuickTime Player\" to $1"; }
osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$ROOT/.build/gate-fixtures/podcast.aiff\"" >/dev/null
sleep 1; qt "play document 1"; sleep 1.5
[ "$(qt 'get playing of document 1')" = true ] || { echo "control: QuickTime did not start"; exit 1; }
"$BIN" --selftest --media pause | grep "media control"; sleep 1
s1=$(qt 'get playing of document 1'); echo "after pause: playing=$s1"
"$BIN" --selftest --media play | grep "media control"; sleep 1
s2=$(qt 'get playing of document 1'); echo "after play: playing=$s2"
qt "pause document 1"
[ "$s1" = false ] && [ "$s2" = true ] && echo MEDIA_GATE_OK
