#!/bin/bash
# Builds the end-to-end fixtures in .build/gate-fixtures from three recordings made on this Mac:
#   podcast.aiff  speech played to the speakers (say -o)
#   raw-leak.wav  the plain built-in mic while that podcast played on the speakers at 50%
#   ec-leak.wav   the echo-cancelled mic during the same playback
# plus a second synthetic voice standing in for a person in the room.
set -euo pipefail
F="$(cd "$(dirname "$0")/../.." && pwd)/.build/gate-fixtures"
cd "$F"
for f in podcast.aiff raw-leak.wav ec-leak.wav; do [ -s "$f" ] || { echo "missing fixture $f"; exit 1; }; done
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
# 24 s of podcast output
ff -i podcast.aiff -t 24 -ar 48000 -ac 1 out-podcast.wav
# 24 s of each mic leak (looped recordings)
# skip the first 2.5 s: echo cancellation is still converging there (the app ignores the mic for 3 s after switching)
ff -ss 2.5 -i ec-leak.wav -c copy ec-leak-settled.wav
ff -stream_loop -1 -i ec-leak-settled.wav -t 24 -ar 48000 -ac 1 mic-ec-leak.wav
ff -stream_loop -1 -i raw-leak.wav -t 24 -ar 48000 -ac 1 mic-raw-leak.wav
# a person talking from 6 s for about 6 s, at a near-mic level, mixed into the echo-cancelled mic
say -v Daniel -o person.aiff "Hey, sorry to interrupt. Can you come and help me with the boxes in the hallway? They are really heavy and I need a hand."
ff -t 6 -i person.aiff -ar 48000 -ac 1 -af "loudnorm=I=-36:TP=-9,adelay=6000" person-delayed.wav
ff -i mic-ec-leak.wav -i person-delayed.wav -filter_complex "amix=inputs=2:duration=first:normalize=0" mic-ec-person.wav
echo "FIXTURES_OK"
