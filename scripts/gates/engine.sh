#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
out=$("$ROOT/.build/release/Hush" --selftest 2>&1); echo "$out" | grep -c "  pass" | sed 's/^/passes: /'
echo "$out" | grep "FAIL" && exit 1
for name in "a podcast is recognised as spoken content" "podcast leak through the echo-cancelled mic never pauses" \
  "a person talking over a podcast pauses it" "plays again after the quiet hold" "podcast leak into a plain mic on speakers never pauses" \
  "if the player ignores the pause, hush lowers the volume" "if someone presses play while paused, hush steps back" \
  "and doesn't pause again while the same conversation" "switching hush off while paused plays it again" \
  "with pausing off, talk over a podcast does nothing" "talking over a song still ducks it" \
  "voice over music ducks" "restores after the hold time" "song lyrics leaking into the mic don't duck" "quiet echo residue that sounds like speech never pauses"; do
  echo "$out" | grep -q "  pass  $name" || { echo "missing: $name"; exit 1; }
done
echo "$out" | grep -q "all checks passed" && echo ENGINE_GATE_OK
