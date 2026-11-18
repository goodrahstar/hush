#!/usr/bin/env python3
"""Reads Hush log lines on stdin. For every pause, looks at the status lines while paused with the output
silent: a real person keeps being heard (mic speech >= 0.6 at >= -45 dB) after the podcast stops; echo
residue cannot outlive the playback. Prints one verdict per pause and FALSE_PAUSES=<n>."""
import re, sys
lines = sys.stdin.read().splitlines()
false = 0
for i, l in enumerate(lines):
    if "pause sent" not in l: continue
    real = False
    # The status line that triggered: on the echo-cancelled mic, residue sits at -51..-65 dB; a voice at -35 dB
    # or louder can only be a person in the room.
    for m in reversed(lines[max(0, i - 2):i]):
        mic = re.search(r"mic\[speech ([\d.]+) [^\]]*level (-?\d+)dB\]", m)
        if " ec |" in m and mic and float(mic.group(1)) >= 0.6 and int(mic.group(2)) >= -35:
            real = True; break
    for m in lines[i + 1:i + 8]:
        if not re.match(r"^[0-9:]+ paused ", m): continue
        out = re.search(r"out\[[^\]]*level (-?\d+)dB\]", m)
        mic = re.search(r"mic\[speech ([\d.]+) [^\]]*level (-?\d+)dB\]", m)
        if out and mic and int(out.group(1)) <= -65 and float(mic.group(1)) >= 0.6 and int(mic.group(2)) >= -45:
            real = True; break
    print(f"{l[:8]} pause: {'a person talking (loud, or still heard after playback stopped)' if real else 'FALSE: nothing heard once playback stopped'}")
    false += 0 if real else 1
print(f"FALSE_PAUSES={false}")
