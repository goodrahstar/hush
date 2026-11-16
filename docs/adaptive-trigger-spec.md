# Adaptive trigger: a portable spec

Source of truth: `Sources/Hush/DecisionEngine.swift` (the mechanism), `Sources/Hush/SelfTest.swift` (`engineScenarios()`), `Sources/Hush/Controller.swift` (the action layer). Every constant below is taken from that code. Text marked **Generalisation** is not in Hush; it is how the pattern carries over to other domains.

## 1. Summary

A noisy confidence score arrives a few times a second. A fixed-rate loop smooths it, subtracts a known leak from a second signal, and only listens while an enabling condition (the gate) holds. It learns a slow baseline of the score while nothing is happening, and sets the trigger threshold just above that baseline, never below a floor set by a sensitivity knob. The score must stay above the threshold for a short attack time to fire. It must stay well below the threshold (60% of it) for a hold time to release. Use it when a classifier score must start and stop a real-world action without chattering: speech over music, motion in a camera feed, anomaly scores, presence detection, wake conditions. Keep the engine pure: readings in, one action out. Apply the action in a separate layer.

## 2. Signals and terms

| Hush name | Generic name | Meaning |
|---|---|---|
| mic `speech` (`Heard.speech` from the microphone) | primary score | Evidence that the event is happening. 0..1. |
| output `max(speech, singing)` → `outputVoice` | leak / confound score | Something that inflates the primary score without being the event. Here: song vocals from the speakers picked up by the mic. |
| output `music` | context score | Says whether the situation the action applies to exists. Feeds the gate. |
| user volume (`volume`), `minVolume` | gate quantity, gate minimum | A second gate input. Nothing to act on below the minimum. |
| `musicOn = music > 0.3 && volume >= minVolume` | gate | Enabling condition. Engine only arms while it holds. |
| `level > -65` dBFS | validity check | A reading from a near-silent source counts as 0. |
| `voice` | smoothed score | `EMA(max(0, primary − 0.5 × smoothedConfound))`. |
| `baseline` | baseline | Slow average of the smoothed score while no event is happening. |
| `threshold(s)` | effective threshold | Floor from sensitivity, lifted by baseline, capped. |
| `.duck` / `.restore` | fire / release | The two actions. |
| `Phase` `.off/.quiet/.listening/.ducked` | off / idle / armed / active | Engine states. |
| `Controller` | action layer | Applies fire/release to the world: ramps, user override, crash recovery. |

## 3. Algorithm

The engine is called once per tick with `dt` seconds (Hush: `dt = 0.1`, a 10 Hz timer). Inputs are the latest readings from each source, or "none" if there is no fresh reading (Hush treats a reading older than 1.5 s as none; that check is in `Controller.tick`). Classifier readings arrive at their own rate (Hush: 1 s windows every 0.25 s); the tick just reuses the last one.

```
state: phase = IDLE
       context = confound = score = baseline = 0
       above = below = gone = 0            # seconds

threshold(s):
    base = clamp(0.85 - 0.5 * s.sensitivity, 0.3, 0.9)
    return min(0.92, max(base, baseline + 0.2))

step(dt, ctxReading, primaryReading, gateValue, s) -> NONE | FIRE | RELEASE:
    # 1. smooth (always, in every state)
    c = ctxReading valid ? ctxReading : zeros          # none or level <= -65 dBFS -> 0
    context  = ema(context,  c.context,  0.3)
    confound = ema(confound, c.confound, 0.3)
    raw   = primaryReading valid ? max(0, primaryReading.primary - 0.5 * confound) : 0
    score = ema(score, raw, 0.5)

    gate = context > 0.3 and gateValue >= s.minGate
    thr  = threshold(s)                                # computed before this tick's baseline update

    # 2. disabled: go OFF, release at once if active
    if not s.enabled:
        was = phase; phase = OFF; above = below = gone = 0
        return RELEASE if was == ACTIVE else NONE

    # 3. not active: arm on gate, learn baseline, count attack
    if phase in (OFF, IDLE, ARMED):
        phase = gate ? ARMED : IDLE
        if not gate: above = below = gone = 0; return NONE
        if score > thr:  above += dt
        else:            above = 0; baseline += 0.02 * (score - baseline)
        if above >= s.attackSeconds:
            phase = ACTIVE; above = below = gone = 0; return FIRE
        return NONE

    # 4. active: count release (gate quantity is NOT checked here)
    below = (score < 0.6 * thr) ? below + dt : 0
    gone  = (context < 0.15)    ? gone  + dt : 0
    if below >= s.holdSeconds or gone >= 2:
        phase = (gone >= 2) ? IDLE : ARMED
        above = below = gone = 0
        return RELEASE
    return NONE

ema(old, new, a) = old + a * (new - old)
```

Details that matter:

- The smoothers run in every state, including OFF and IDLE. A missing reading pulls them toward 0.
- The baseline updates only in ARMED and only on ticks where `score <= thr`. It is never reset by `reset()`; only a new engine resets it.
- Any single tick at or below threshold zeroes the attack counter. Any single tick at or above `0.6 × thr` zeroes the release counter.
- The context score has its own hysteresis: arming needs `context > 0.3`; the "context gone" release needs `context < 0.15` for 2 s.
- While ACTIVE the gate quantity is ignored. Hush passes the pre-action volume while ducked (and 0 if muted), so the engine sees the user's volume, not the ducked one.

### State machine

| From | Condition (checked in this order) | To | Action |
|---|---|---|---|
| any | `enabled == false` | OFF | RELEASE if from ACTIVE, else NONE |
| OFF / IDLE / ARMED | gate false | IDLE | NONE (counters reset) |
| OFF / IDLE / ARMED | gate true, `above < attack` | ARMED | NONE |
| OFF / IDLE / ARMED | gate true, `above >= attack` | ACTIVE | FIRE |
| ACTIVE | `gone >= 2 s` | IDLE | RELEASE |
| ACTIVE | `below >= hold` (and context not gone) | ARMED | RELEASE |
| ACTIVE | otherwise | ACTIVE | NONE |

OFF to ARMED can happen in one tick, and the attack count starts in that same tick. After a release to ARMED, a new FIRE needs a full attack again.

## 4. Parameters

Time constant of an EMA with factor `a` at tick `dt`: `tau = -dt / ln(1 - a)`. Values below use `dt = 0.1 s`.

| Name (Hush) | Hush value | Controls | How to tune | Time-constant reading |
|---|---|---|---|---|
| tick `dt` | 0.1 s (10 Hz) | Loop rate | Faster than the classifier's output rate is enough; all EMA factors are per tick, so change them if you change `dt`. | — |
| context EMA (`music`) | 0.3 | Smoothing of the context score | Lower for steadier gating. | ≈ 0.28 s |
| confound EMA (`outputVoice`) | 0.3 | Smoothing of the leak score | Match the delay between the leak source and the primary sensor. | ≈ 0.28 s |
| score EMA (`voice`) | 0.5 | Smoothing of the primary score | Higher reacts faster; lower rejects spikes. | ≈ 0.14 s |
| `leak` | 0.5 | Fraction of confound subtracted from primary | Measure: primary score with the confound present and no event, divided by confound score. Too high hides real events. | — |
| validity floor | −65 dBFS | Below it a reading counts as 0 | Set at the noise floor of the source. | — |
| context on | `> 0.3` | Gate arms | Raise if the context classifier false-positives. | — |
| context gone | `< 0.15` for 2 s | Forced release | Keep below "context on" for hysteresis. | 2 s |
| `minVolume` | 0.1 | Gate quantity minimum | Domain specific. Not user-saved in Hush. | — |
| `sensitivity` | 0.6 (0..1, user setting) | Threshold floor `clamp(0.85 − 0.5·s, 0.3, 0.9)` | 0.6 gives 0.55. Range 0..1 gives 0.85..0.35. Clamp only bites outside 0..1. | — |
| baseline rate | 0.02 | How fast the baseline follows the idle score | Lower for slower, more stable adaptation. | ≈ 4.95 s (about 5 s) |
| baseline margin | +0.2 | Threshold sits this far above the baseline | Wider margin, fewer false fires. Lifts the threshold only when baseline > floor − 0.2 (0.35 at default). | — |
| threshold cap | 0.92 | Highest threshold | Keep below the score a clear event reaches. Reached when baseline ≥ 0.72. | — |
| `attackSeconds` | 0.3 s | Time above threshold to fire | Longer filters short blips (Hush: coughs, single words). At 10 Hz this is 3 ticks. Not user-saved. | 0.3 s |
| release ratio | 0.6 × threshold | Release level | Lower widens the hysteresis band. At default thr 0.55 the release level is 0.33. | — |
| `holdSeconds` | 2.5 s (user setting) | Time below release level to release | Longer rides out pauses. | 2.5 s |
| stale reading | 1.5 s (Controller) | Older readings count as none | A bit over the classifier's window plus hop. | — |

With the Hush test inputs (song playing, mic speech jumping 0.1 → 0.9) the engine fires about 0.5 s after onset and releases about 2.5 s after the speech stops.

## 5. Action layer (Controller.swift)

The engine only says FIRE or RELEASE. `Controller` turns that into volume changes.

- **Fire (duck).** If the output can't set volume, it reports a problem and does nothing else. Otherwise it records the current volume as `duckedFrom`, clears the override flag, saves the volume to persistent storage (`savedVolume`), and ramps to `max(0.03, current × duckTo)` over 0.35 s. `duckTo` is 0.3 (about −10 dB on Mac speakers).
- **Release (restore).** If nothing was ducked, it does nothing. Otherwise it clears `duckedFrom` and `savedVolume`. If the user took over, it stops there. Else it ramps back to `duckedFrom` over 1.5 s.
- **Ramps.** 40 steps per second, ease-out cubic `1 − (1 − t)^3`. A new ramp cancels the old one. After each write it stores the value read back as `lastWritten`.
- **User override wins.** On each tick, if something is ducked, no ramp is running, and the current volume differs from `lastWritten` by more than 0.04, it sets `userTookOver`. The later release then leaves the volume alone. The check is skipped during ramps so the ramp's own writes don't count.
- **What the engine sees.** The gate value passed in is `duckedFrom ?? current`, or 0 when muted.
- **Persist and restore on crash.** `savedVolume` is written on fire and removed on release. On launch, if it exists, the volume is set back to it and the key removed. On normal quit, the volume is restored if ducked and the user did not take over, and the key is removed.
- **Output device change.** If the music was ducked and the user had not taken over, it first sets the old device back to the pre-duck volume. Then it cancels the ramp, clears `duckedFrom`, `userTookOver` and `savedVolume`, replaces the engine with a new one (baseline back to 0), and restarts the output tap.
- **Saved settings.** `enabled`, `duckTo`, `sensitivity`, `holdSeconds` are saved. `minVolume` and `attackSeconds` always use their defaults.

**Generalisation.** Fire and release map to any reversible action: dim, pause, mute, raise an alert level. Keep these rules: remember the pre-action state, persist it before acting, ramp instead of jumping when the action is perceptible, and if a person changes the controlled value while the action is on, don't undo their change.

## 6. Known limits

- The baseline learns only while ARMED and at or below threshold. A background that jumps above threshold fires instead of being learned. If it stays high, the engine stays ACTIVE until the context goes away or the score falls below 0.6 × threshold.
- The baseline does not learn while ACTIVE, IDLE or OFF. It is frozen, not reset, across those states.
- The baseline is not persisted. It starts at 0 on every launch and on every output device change (new engine).
- The baseline needs about 5 s (time constant) of idle time to adapt, so a new noisy background can fire in its first seconds.
- The leak factor 0.5 is fixed, not learned. A setup with more or less bleed is handled only through the baseline.
- No tolerance in the counters: one low tick zeroes the attack count; one high tick zeroes the release count.
- The threshold cap 0.92 means a very noisy background can leave only a small margin, or none, for real events.
- If the volume can't be set, the engine still moves to ACTIVE; the later release is a no-op because nothing was recorded.
- Timing is quantised to the tick: attack 0.3 s is 3 ticks at 10 Hz, plus the EMA rise time.

## 7. Test scenarios to port

From `SelfTest.engineScenarios()`, run at 10 Hz (`dt = 0.1`), default settings, gate value 0.6, ticks per segment `int(seconds × 10)`. Inputs (Hush values): song = context 0.9, confound 0.5 (singing 0.5); room = primary 0.1, level −40; talking = primary 0.9, level −25. Steps in one bullet run on the same engine in order.

- [ ] Primary high, no context reading for 5 s: no action.
- [ ] Context on, primary low for 10 s: no action, state is ARMED. Then on the same engine:
  - [ ] primary high for 1.5 s: exactly one FIRE.
  - [ ] primary high 2 s more: no action.
  - [ ] primary low 2.0 s: no action (short gap held).
  - [ ] primary low 2.5 s more: exactly one RELEASE.
- [ ] After 5 s idle with context on, primary high for 0.2 s: no action (blip).
- [ ] Idle 5 s, high 1.5 s (fires), then context source silent (level −90) with primary still high for 3 s: exactly one RELEASE.
- [ ] Context on, primary high, gate value 0.05 (below 0.1) for 5 s: no action.
- [ ] Leak: context 0.8, confound 0.8 (speech 0.5, singing 0.8), primary 0.55 for 20 s: no action. Then primary 0.97 for 2 s: exactly one FIRE.
- [ ] Idle 5 s, high 1.5 s (fires), then one tick with `enabled = false`: exactly one RELEASE.

Extra, not in Hush's suite (added for the Python port):

- [ ] Context on, no confound, primary 0.5 for 60 s: threshold ≈ 0.70 (baseline ≈ 0.5). Then primary 0.65 for 5 s: no action. (A fresh engine fires on 0.65.)

**Generalisation.** For a new domain, keep the same shapes: gate closed never fires; gate open with idle input never fires; sustained evidence fires once; continued evidence doesn't re-fire; a gap shorter than hold doesn't release; a gap longer than hold releases once; a blip shorter than attack is ignored; losing context releases; a sub-minimum gate value never fires; a known leak alone never fires but real evidence over it does; disabling while active releases at once.

## Reference implementation (Python, pure, no dependencies)

Mirrors `DecisionEngine.swift` line for line. The Swift engine takes two classifier readings (`Heard`, with speech, music, singing and level); here one `Obs` type carries the fields each side needs. Hush's mapping: context reading from the output (`context = music`, `confound = max(speech, singing)`, `valid_context = level > -65`); primary reading from the mic (`primary = speech`, `valid_primary = level > -65`); `gate_value` = user volume.

`trigger.py`:

```python
"""Adaptive trigger: pure, deterministic port of Hush's DecisionEngine."""
from dataclasses import dataclass

@dataclass
class Settings:
    enabled: bool = True
    sensitivity: float = 0.6     # 0..1, higher fires on weaker evidence
    hold_s: float = 2.5          # quiet time before release
    min_gate: float = 0.1        # gate quantity must be at least this
    attack_s: float = 0.3        # evidence must last this long

@dataclass
class Obs:                       # one classifier reading; None = no fresh reading
    primary: float = 0.0         # Hush: mic speech
    context: float = 0.0         # Hush: output music
    confound: float = 0.0        # Hush: max(output speech, output singing)
    valid_primary: bool = True   # Hush: mic level > -65 dBFS
    valid_context: bool = True   # Hush: output level > -65 dBFS

LEAK = 0.5
OFF, QUIET, LISTENING, ACTIVE = "off", "quiet", "listening", "active"
NONE, FIRE, RELEASE = "none", "fire", "release"

def ema(old, new, a): return old + a * (new - old)

class Engine:
    def __init__(self):
        self.phase = QUIET
        self.context = self.confound = self.score = self.baseline = 0.0
        self.above = self.below = self.gone = 0.0

    def threshold(self, s):
        base = min(max(0.85 - 0.5 * s.sensitivity, 0.3), 0.9)
        return min(0.92, max(base, self.baseline + 0.2))

    def _reset(self): self.above = self.below = self.gone = 0.0

    def step(self, dt, ctx, pri, gate_value, s):
        ctx = ctx or Obs(valid_context=False)
        pri = pri or Obs(valid_primary=False)
        self.context = ema(self.context, ctx.context if ctx.valid_context else 0, 0.3)
        self.confound = ema(self.confound, ctx.confound if ctx.valid_context else 0, 0.3)
        raw = max(0, pri.primary - LEAK * self.confound) if pri.valid_primary else 0
        self.score = ema(self.score, raw, 0.5)
        gate = self.context > 0.3 and gate_value >= s.min_gate
        thr = self.threshold(s)
        if not s.enabled:
            was, self.phase = self.phase, OFF
            self._reset()
            return RELEASE if was == ACTIVE else NONE
        if self.phase != ACTIVE:
            self.phase = LISTENING if gate else QUIET
            if not gate:
                self._reset(); return NONE
            if self.score > thr:
                self.above += dt
            else:
                self.above = 0
                self.baseline += 0.02 * (self.score - self.baseline)
            if self.above >= s.attack_s:
                self.phase = ACTIVE; self._reset(); return FIRE
            return NONE
        self.below = self.below + dt if self.score < thr * 0.6 else 0
        self.gone = self.gone + dt if self.context < 0.15 else 0
        if self.below >= s.hold_s or self.gone >= 2:
            self.phase = QUIET if self.gone >= 2 else LISTENING
            self._reset(); return RELEASE
        return NONE
```

`test_trigger.py` (run with `python3 -I test_trigger.py <dir containing trigger.py>`):

```python
import sys; sys.path.insert(0, sys.argv[1])
from trigger import Engine, Settings, Obs, FIRE, RELEASE, LISTENING, NONE

def play(e, secs, ctx, pri, gate=0.6, s=None):
    s = s or Settings()
    return [a for a in (e.step(0.1, ctx, pri, gate, s) for _ in range(int(secs * 10))) if a != NONE]

# Hush inputs mapped: ctx from system output, pri from mic.
song = Obs(context=0.9, confound=0.5)                      # music 0.9, singing 0.5
room = Obs(primary=0.1)                                     # mic speech 0.1
talking = Obs(primary=0.9)                                  # mic speech 0.9
fails = 0
def check(ok, what):
    global fails; print(("  pass  " if ok else "  FAIL  ") + what); fails += not ok

e = Engine(); check(play(e, 5, None, talking) == [], "evidence with the gate closed never fires")
e = Engine(); check(play(e, 10, song, room) == [] and e.phase == LISTENING, "gate open, no evidence: never fires")
check(play(e, 1.5, song, talking) == [FIRE], "sustained evidence fires within 1.5 s")
check(play(e, 2, song, talking) == [], "stays active while evidence continues")
check(play(e, 2.0, song, room) == [], "waits out a short gap")
check(play(e, 2.5, song, room) == [RELEASE], "releases after the hold time")
e = Engine(); play(e, 5, song, room)
check(play(e, 0.2, song, talking) == [], "a 0.2 s blip is ignored")
e = Engine(); play(e, 5, song, room); play(e, 1.5, song, talking)
check(play(e, 3, Obs(valid_context=False), talking) == [RELEASE], "releases when the gate context goes away")
e = Engine(); check(play(e, 5, song, talking, gate=0.05) == [], "gate quantity below minimum: never fires")
e = Engine(); vocal = Obs(context=0.8, confound=0.8)       # max(speech 0.5, singing 0.8)
check(play(e, 20, vocal, Obs(primary=0.55)) == [], "known leak into the primary signal does not fire")
check(play(e, 2, vocal, Obs(primary=0.97)) == [FIRE], "real evidence over the leak still fires")
e = Engine(); play(e, 5, song, room); play(e, 1.5, song, talking)
check(play(e, 0.1, song, talking, s=Settings(enabled=False)) == [RELEASE], "disabling while active releases at once")
# Extra, not in Hush's suite: the baseline lifts the threshold for a steady background.
inst = Obs(context=0.9)                                     # gate open, no confound
e = Engine(); play(e, 60, inst, Obs(primary=0.5))
check(abs(e.threshold(Settings()) - 0.7) < 0.01, "steady 0.5 background lifts threshold from 0.55 to ~0.70")
check(play(e, 5, inst, Obs(primary=0.65)) == [], "0.65 no longer fires after adaptation")
print("all checks passed" if fails == 0 else f"{fails} check(s) failed"); sys.exit(1 if fails else 0)
```

Result:

```
  pass  evidence with the gate closed never fires
  pass  gate open, no evidence: never fires
  pass  sustained evidence fires within 1.5 s
  pass  stays active while evidence continues
  pass  waits out a short gap
  pass  releases after the hold time
  pass  a 0.2 s blip is ignored
  pass  releases when the gate context goes away
  pass  gate quantity below minimum: never fires
  pass  known leak into the primary signal does not fire
  pass  real evidence over the leak still fires
  pass  disabling while active releases at once
  pass  steady 0.5 background lifts threshold from 0.55 to ~0.70
  pass  0.65 no longer fires after adaptation
all checks passed
```

## 8. Prompt for an LLM

Paste this, then fill in the placeholders.

````text
Implement an "adaptive trigger" decision engine for {DOMAIN} in {LANGUAGE}.

Signals:
- Primary score: {PRIMARY_SIGNAL}, a classifier confidence in 0..1, arriving about {INPUT_RATE} times a second.
- Confound score: {CONFOUND_SIGNAL}, a confidence in 0..1 for something that inflates the primary score without being the event.
- Context score: {CONTEXT_SIGNAL}, a confidence in 0..1 that the situation the action applies to exists.
- Gate quantity: {GATE_QUANTITY} with minimum {GATE_MIN}. The gate is "context > 0.3 and gate quantity >= minimum". Gate meaning: {GATE}.
- Validity: a reading counts as all zeros if it is missing, older than {STALE_SECONDS} s, or fails {VALIDITY_CHECK}.
- Action: FIRE means {ACTION}; RELEASE undoes it.

Engine rules (keep these constants unless told otherwise):
1. Fixed tick, dt = 0.1 s. Keep the last reading from each source between ticks.
2. Each tick, in every state: context = EMA(context, reading, 0.3); confound = EMA(confound, reading, 0.3);
   score = EMA(score, max(0, primary - 0.5 * confound), 0.5). EMA(old, new, a) = old + a * (new - old).
3. threshold = min(0.92, max(clamp(0.85 - 0.5 * sensitivity, 0.3, 0.9), baseline + 0.2)), computed before
   this tick's baseline update. Default sensitivity 0.6.
4. States: OFF, IDLE, ARMED, ACTIVE. If disabled: go OFF, zero counters, return RELEASE only if it was ACTIVE.
5. Not ACTIVE: state = ARMED if gate else IDLE. If no gate: zero counters, return NONE.
   If score > threshold: above += dt. Else: above = 0 and baseline += 0.02 * (score - baseline).
   If above >= attack (0.3 s): go ACTIVE, zero counters, return FIRE.
6. ACTIVE (do not check the gate quantity): below += dt while score < 0.6 * threshold, else 0;
   gone += dt while context < 0.15, else 0. If below >= hold (2.5 s) or gone >= 2 s: zero counters,
   go IDLE if gone >= 2 else ARMED, return RELEASE.
7. The baseline is never reset by counter resets; only a new engine resets it.

Requirements:
- The engine is pure and deterministic: no clocks, I/O, threads or randomness. step(dt, contextReading,
  primaryReading, gateQuantity, settings) -> NONE | FIRE | RELEASE. Expose state, smoothed scores,
  baseline and threshold for logging.
- Put the action in a separate layer that: records the pre-action state and persists it before acting;
  ramps perceptible changes (ease-out); if a person changes the controlled value while ACTIVE, keeps
  their change on RELEASE; on startup restores any persisted pre-action state left by a crash;
  passes the pre-action gate quantity to the engine while ACTIVE.
- Write scenario tests that drive the engine at 10 Hz with constant inputs per segment and assert the
  exact list of non-NONE actions:
  gate closed never fires; gate open with idle input never fires and ends ARMED; sustained evidence
  fires once within 1.5 s; continued evidence does not re-fire; a 2.0 s gap does not release; a further
  2.5 s releases once; a 0.2 s blip is ignored; losing context releases within 3 s; a sub-minimum gate
  quantity never fires; confound alone (primary 0.55, confound 0.8) never fires over 20 s, but primary
  0.97 over it fires within 2 s; disabling while ACTIVE releases on the next tick; a steady idle
  primary of 0.5 raises the threshold to about 0.70 after 60 s.
- Then list which constants I should re-measure for {DOMAIN} and how.
````
