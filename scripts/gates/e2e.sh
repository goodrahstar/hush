#!/bin/bash
# positive: echo-cancelled mic + person from 6-12 s -> exactly one pause (6-8.5 s) and one resume (13-17.5 s)
# negative: podcast leak only (raw mic and echo-cancelled mic) -> no events at all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; F="$ROOT/.build/gate-fixtures"; BIN="$ROOT/.build/release/Hush"
bash "$ROOT/scripts/gates/fixtures.sh" >/dev/null
if [ "${1:-}" = positive ]; then
  out=$("$BIN" --selftest --path ec --simulate "$F/out-podcast.wav" "$F/mic-ec-person.wav" 2>&1); echo "$out" | grep -E "event|info  path"
  python3 - "$out" <<'PY'
import re,sys
ev=re.findall(r'event\s+([\d.]+) s\s+(\w+)',sys.argv[1])
kinds=[k for _,k in ev]; t=[float(x) for x,_ in ev]
assert kinds==['pause','resume'], f"expected pause then resume, got {ev}"
assert 6.0<=t[0]<=8.5, f"pause at {t[0]}s, expected 6-8.5"
assert 13.0<=t[1]<=17.5, f"resume at {t[1]}s, expected 13-17.5"
print("E2E_POSITIVE_OK")
PY
else
  for p in "raw mic-raw-leak" "ec mic-ec-leak"; do set -- $p
    out=$("$BIN" --selftest --path $1 --simulate "$F/out-podcast.wav" "$F/$2.wav" 2>&1); echo "$out" | grep -E "event|info  path"
    echo "$out" | grep -q "info  path .* 0 event(s)" || { echo "events on $2 with path $1"; exit 1; }
  done
  echo "E2E_NEGATIVE_OK"
fi
