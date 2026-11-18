import Foundation

struct DuckSettings: Equatable {
    var enabled = true
    /// Ducked volume as a fraction of the volume before ducking. 0.3 ≈ −10 dB on Mac speakers.
    var duckTo = 0.3
    /// 0…1. Higher reacts to quieter or shorter speech.
    var sensitivity = 0.6
    /// How long the room must stay quiet before the music comes back.
    var holdSeconds = 2.5
    /// Ignore playback below this system volume; nothing to duck.
    var minVolume = 0.1
    /// How long speech must last before acting. Filters coughs and single words.
    var attackSeconds = 0.3
    /// Podcasts, videos and other spoken content get paused (not ducked) when someone talks.
    var pauseTalk = true
}

enum Phase: Equatable {
    case off        // disabled
    case quiet      // nothing worth acting on is playing
    case listening  // music or talk on, waiting for a voice in the room
    case ducked     // someone is talking, music is down
    case paused     // someone is talking, the podcast or video is paused
}

/// What the Mac is playing right now.
enum Content: Equatable {
    case none
    case music  // songs, instrumentals: lowered when someone talks
    case talk   // podcasts, videos, people talking: paused when someone talks
}

enum Action: Equatable { case none, duck, restore, pause, resume }

/// How the mic hears the room. Decides how much of the Mac's own playback we assume leaks into it.
enum MicPath: Equatable {
    case speakersRaw     // speakers playing, plain mic: the mic hears the playback
    case echoCancelled   // speakers playing, Apple's echo cancellation removes the playback
    case headphones      // nothing leaks
}

/// The decision layer. Pure and deterministic: smoothed classifier confidences in, one action out.
/// Rules: act only when something is really playing and a voice that isn't part of the playback is heard
/// for long enough. Music is lowered; spoken content is paused (if allowed). Undo after the room has been
/// quiet for `holdSeconds`, or the playback stops.
struct DecisionEngine {
    private(set) var phase: Phase = .quiet
    private(set) var content: Content = .none
    private(set) var music = 0.0        // smoothed P(music) in system output
    private(set) var outputVoice = 0.0  // smoothed P(speech or singing) in system output (lyrics, podcasts)
    private(set) var outputSpeech = 0.0 // smoothed P(speech) in system output (people talking, not singing)
    private(set) var outputSinging = 0.0
    private(set) var voice = 0.0        // smoothed "a person in the room is talking" score from the mic
    private(set) var baseline = 0.0     // what the mic usually scores with this playback and no one talking
    /// Loudness of what's left after echo cancellation when nobody talks (dBFS). A person in the room is
    /// much louder (measured: residual echo −51…−65 dB, voices −17…−44 dB), so speech only counts above it.
    private(set) var residualLevel = -62.0
    private var above = 0.0, below = 0.0, gone = 0.0
    // paused bookkeeping
    private var pausedFor = 0.0, silentSeen = false, activeAgain = 0.0
    /// False after someone overrides Hush (presses play while paused): wait for a quiet room before acting again.
    private var armed = true, quietFor = 0.0

    static let leak = 0.5 // how much output vocals we assume bleed from speakers into a plain mic
    /// After pausing, how long the player gets to actually go quiet before we call the pause failed.
    static let pauseGrace = 2.0

    func threshold(_ s: DuckSettings) -> Double {
        let base = min(max(0.85 - 0.5 * s.sensitivity, 0.3), 0.9)
        return min(0.92, max(base, baseline + 0.2))
    }

    /// `volume` is the user's volume (the pre-duck value while ducked).
    mutating func step(dt: Double, system: Heard?, mic: Heard?, volume: Double, settings s: DuckSettings,
                       micPath: MicPath = .speakersRaw) -> Action {
        let sys = system ?? Heard()
        let room = mic ?? Heard()
        let sysAudible = sys.level > -65
        music = ema(music, sysAudible ? sys.music : 0, 0.3)
        outputVoice = ema(outputVoice, sysAudible ? max(sys.speech, sys.singing) : 0, 0.3)
        outputSpeech = ema(outputSpeech, sysAudible ? sys.speech : 0, 0.3)
        outputSinging = ema(outputSinging, sysAudible ? sys.singing : 0, 0.3)
        let leak = micPath == .speakersRaw ? Self.leak : 0
        var raw = room.level > -65 ? max(0, room.speech - leak * outputVoice) : 0
        if micPath == .echoCancelled, mic != nil {
            raw *= min(max((room.level - residualLevel - 4) / 8, 0), 1) // 0 near the echo floor, full 12 dB above
        }
        voice = ema(voice, raw, 0.5)
        content = classify()

        let loudEnough = volume >= s.minVolume
        let musicOn = content == .music && loudEnough
        let talkOn = content == .talk && loudEnough && s.pauseTalk
        let thr = threshold(s)

        if !s.enabled {
            armed = true; quietFor = 0
            let was = phase
            phase = .off; reset()
            return was == .ducked ? .restore : was == .paused ? .resume : .none
        }

        switch phase {
        case .off, .quiet, .listening:
            let on = musicOn || talkOn
            phase = on ? .listening : .quiet
            guard on else { reset(); return .none }
            if !armed {
                quietFor = voice < thr * 0.6 ? quietFor + dt : 0
                if quietFor >= s.holdSeconds { armed = true; quietFor = 0 }
                return .none
            }
            if voice > thr {
                above += dt
            } else {
                above = 0
                baseline += 0.02 * (voice - baseline) // learn the room slowly, only while nobody talks
                if micPath == .echoCancelled, mic != nil, room.level > -100 {
                    residualLevel = min(max(residualLevel + 0.03 * (room.level - residualLevel), -75), -45)
                }
            }
            // Pausing is more disruptive than lowering: it waits for half a second of speech, not a single word.
            if above >= (talkOn ? max(s.attackSeconds, 0.5) : s.attackSeconds) {
                reset()
                if talkOn { phase = .paused; return .pause }
                phase = .ducked; return .duck
            }
            return .none

        case .ducked:
            below = voice < thr * 0.6 ? below + dt : 0
            gone = music < 0.15 && outputVoice < 0.15 ? gone + dt : 0
            if below >= s.holdSeconds || gone >= 2 {
                phase = gone >= 2 ? .quiet : .listening
                reset()
                return .restore
            }
            return .none

        case .paused:
            pausedFor += dt
            let playing = sysAudible && (sys.music > 0.3 || sys.speech > 0.3)
            if !playing { silentSeen = true }
            // The player never went quiet: it ignored the pause. Lower the volume instead.
            if !silentSeen && pausedFor >= Self.pauseGrace {
                phase = .ducked; reset()
                return .duck
            }
            // It went quiet, then started again on its own: someone pressed play. Their choice wins.
            activeAgain = silentSeen && playing ? activeAgain + dt : 0
            if activeAgain >= 1.0 {
                phase = .listening; reset()
                armed = false; quietFor = 0
                return .none
            }
            below = voice < thr * 0.6 ? below + dt : 0
            if below >= s.holdSeconds && pausedFor >= Self.pauseGrace {
                phase = .listening; reset()
                return .resume
            }
            return .none
        }
    }

    /// Spoken content: clear speech, little singing, and the speech outweighs the music.
    /// Hysteresis keeps a podcast's music bed or a pause between sentences from flipping the mode.
    private func classify() -> Content {
        let talkNow = outputSpeech >= (content == .talk ? 0.35 : 0.5) && outputSinging < 0.3 && outputSpeech > music
        if talkNow { return .talk }
        if music > 0.3 { return .music }
        if content == .talk && outputSpeech >= 0.35 { return .talk }
        return .none
    }

    private mutating func reset() {
        above = 0; below = 0; gone = 0
        pausedFor = 0; silentSeen = false; activeAgain = 0
    }
    private func ema(_ old: Double, _ new: Double, _ a: Double) -> Double { old + a * (new - old) }
}
