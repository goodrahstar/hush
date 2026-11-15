import Foundation

struct DuckSettings: Equatable {
    var enabled = true
    /// Ducked volume as a fraction of the volume before ducking. 0.3 ≈ −10 dB on Mac speakers.
    var duckTo = 0.3
    /// 0…1. Higher reacts to quieter or shorter speech.
    var sensitivity = 0.6
    /// How long the room must stay quiet before the music comes back.
    var holdSeconds = 2.5
    /// Ignore music below this system volume; nothing to duck.
    var minVolume = 0.1
    /// How long speech must last before ducking. Filters coughs and single words.
    var attackSeconds = 0.3
}

enum Phase: Equatable {
    case off        // disabled
    case quiet      // no music playing
    case listening  // music on, waiting for a voice
    case ducked     // someone is talking, music is down
}

enum Action: Equatable { case none, duck, restore }

/// The decision layer. Pure and deterministic: smoothed classifier confidences in, one action out.
/// Rules: duck only when music is really playing and a voice that isn't part of the music is heard
/// for long enough; restore after the room has been quiet for `holdSeconds`, or the music stops.
struct DecisionEngine {
    private(set) var phase: Phase = .quiet
    private(set) var music = 0.0       // smoothed P(music) in system output
    private(set) var outputVoice = 0.0 // smoothed P(speech or singing) in system output (lyrics, podcasts)
    private(set) var voice = 0.0       // smoothed "a person in the room is talking" score from the mic
    private(set) var baseline = 0.0    // what the mic usually scores with this music and no one talking
    private var above = 0.0, below = 0.0, musicGone = 0.0

    static let leak = 0.5 // how much output vocals we assume bleed from speakers into the mic

    func threshold(_ s: DuckSettings) -> Double {
        let base = min(max(0.85 - 0.5 * s.sensitivity, 0.3), 0.9)
        return min(0.92, max(base, baseline + 0.2))
    }

    /// `volume` is the user's volume (the pre-duck value while ducked).
    mutating func step(dt: Double, system: Heard?, mic: Heard?, volume: Double, settings s: DuckSettings) -> Action {
        let sys = system ?? Heard()
        let room = mic ?? Heard()
        let sysAudible = sys.level > -65
        music = ema(music, sysAudible ? sys.music : 0, 0.3)
        outputVoice = ema(outputVoice, sysAudible ? max(sys.speech, sys.singing) : 0, 0.3)
        let raw = room.level > -65 ? max(0, room.speech - Self.leak * outputVoice) : 0
        voice = ema(voice, raw, 0.5)

        let musicOn = music > 0.3 && volume >= s.minVolume
        let thr = threshold(s)

        if !s.enabled {
            let was = phase
            phase = .off; reset()
            return was == .ducked ? .restore : .none
        }

        switch phase {
        case .off, .quiet, .listening:
            phase = musicOn ? .listening : .quiet
            guard musicOn else { reset(); return .none }
            if voice > thr {
                above += dt
            } else {
                above = 0
                baseline += 0.02 * (voice - baseline) // learn the room slowly, only while nobody talks
            }
            if above >= s.attackSeconds {
                phase = .ducked; reset()
                return .duck
            }
            return .none

        case .ducked:
            below = voice < thr * 0.6 ? below + dt : 0
            musicGone = music < 0.15 ? musicGone + dt : 0
            if below >= s.holdSeconds || musicGone >= 2 {
                phase = musicGone >= 2 ? .quiet : .listening
                reset()
                return .restore
            }
            return .none
        }
    }

    private mutating func reset() { above = 0; below = 0; musicGone = 0 }
    private func ema(_ old: Double, _ new: Double, _ a: Double) -> Double { old + a * (new - old) }
}
