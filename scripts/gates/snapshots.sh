#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; D="$ROOT/.build/snapshots"; rm -rf "$D"
"$ROOT/.build/release/Hush" --selftest --snapshot "$D" | grep -E "wrote|FAIL"
for n in talk paused listening ducked off; do
  f="$D/panel-$n.png"; [ -s "$f" ] || { echo "missing $f"; exit 1; }
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}'); echo "$n: ${h}px tall"; [ "$h" -gt 600 ] || exit 1
done
echo SNAPSHOT_GATE_OK
