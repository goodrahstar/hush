#!/bin/bash
# Voice processing silences process taps in the same process; Hush runs it in a helper process.
# Plays the podcast fixture so the tap has something to deliver, then checks both streams.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
qt() { osascript -e "tell application \"QuickTime Player\" to $1"; }
osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$ROOT/.build/gate-fixtures/podcast.aiff\"" >/dev/null
sleep 1; qt "play document 1"
out=$("$ROOT/.build/release/Hush" --selftest --tapvp 2>&1 || true)
playing=$(qt 'get playing of document 1'); qt "pause document 1"
echo "$out" | grep -E "info|pass|FAIL"; echo "quicktime still playing: $playing"
echo "$out" | grep -q "pass  the tap keeps delivering" && echo "$out" | grep -q "pass  the echo-cancelled mic helper sends results" && [ "$playing" = true ] && echo TAPVP_GATE_OK
