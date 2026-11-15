import AVFoundation
import SwiftUI

/// `Hush --selftest [--classify file ...] [--snapshot dir]`
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  pass  \(what)" : "  FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func run(_ args: [String]) -> Int32 {
        print("decision engine")
        engineScenarios()

        print("system volume")
        let v = SystemVolume.get()
        check(v != nil, "reads output volume of \(CA.name(CA.defaultOutputDevice)): \(v.map { String(format: "%.2f", $0) } ?? "n/a")")
        print("  info  volume settable: \(SystemVolume.canSet()), built-in mic: \(CA.builtInMicrophone.map(CA.name) ?? "none")")

        var i = 0
        while i < args.count {
            if args[i] == "--classify", i + 1 < args.count { classify(args[i + 1]); i += 1 }
            if args[i] == "--simulate", i + 2 < args.count { simulate(system: args[i + 1], mic: args[i + 2]); i += 2 }
            if args[i] == "--snapshot", i + 1 < args.count { snapshot(to: args[i + 1]); i += 1 }
            i += 1
        }
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: engine

    private static func h(speech: Double = 0, music: Double = 0, singing: Double = 0, level: Double = -20) -> Heard {
        Heard(speech: speech, music: music, singing: singing, level: level)
    }

    /// Runs `seconds` of 10 Hz ticks, returns the actions that fired.
    private static func play(_ e: inout DecisionEngine, _ seconds: Double, sys: Heard?, mic: Heard?,
                             volume: Double = 0.6, settings: DuckSettings = DuckSettings()) -> [Action] {
        var out: [Action] = []
        for _ in 0..<Int(seconds * 10) {
            let a = e.step(dt: 0.1, system: sys, mic: mic, volume: volume, settings: settings)
            if a != .none { out.append(a) }
        }
        return out
    }

    private static func engineScenarios() {
        let song = h(music: 0.9, singing: 0.5)
        let roomWithMusic = h(speech: 0.1, music: 0.6, level: -40)
        let talking = h(speech: 0.9, music: 0.4, level: -25)

        var e = DecisionEngine()
        check(play(&e, 5, sys: nil, mic: talking).isEmpty, "talking with no music never ducks")

        e = DecisionEngine()
        check(play(&e, 10, sys: song, mic: roomWithMusic).isEmpty && e.phase == .listening, "music alone never ducks")
        check(play(&e, 1.5, sys: song, mic: talking) == [.duck], "voice over music ducks within 1.5 s")
        check(play(&e, 2, sys: song, mic: talking).isEmpty, "keeps ducked while talking continues")
        check(play(&e, 2.0, sys: song, mic: roomWithMusic).isEmpty, "waits out a short pause")
        check(play(&e, 2.5, sys: song, mic: roomWithMusic) == [.restore], "restores after the hold time")

        e = DecisionEngine()
        _ = play(&e, 5, sys: song, mic: roomWithMusic)
        check(play(&e, 0.2, sys: song, mic: talking).isEmpty, "a 0.2 s blip (cough, one word) is ignored")

        e = DecisionEngine()
        _ = play(&e, 5, sys: song, mic: roomWithMusic)
        _ = play(&e, 1.5, sys: song, mic: talking)
        check(play(&e, 3, sys: h(level: -90), mic: talking) == [.restore], "restores when the music stops")

        e = DecisionEngine()
        check(play(&e, 5, sys: song, mic: talking, volume: 0.05).isEmpty, "ignores music below the minimum volume")

        // Speakers playing a vocal-heavy song: the mic hears the lyrics as moderate speech.
        e = DecisionEngine()
        let vocalSong = h(speech: 0.5, music: 0.8, singing: 0.8)
        let leak = h(speech: 0.55, music: 0.6, level: -35)
        check(play(&e, 20, sys: vocalSong, mic: leak).isEmpty, "song lyrics leaking into the mic don't duck")
        check(play(&e, 2, sys: vocalSong, mic: h(speech: 0.97, level: -22)) == [.duck], "a real voice over a vocal song still ducks")

        e = DecisionEngine()
        _ = play(&e, 5, sys: song, mic: roomWithMusic)
        _ = play(&e, 1.5, sys: song, mic: talking)
        var off = DuckSettings(); off.enabled = false
        check(play(&e, 0.1, sys: song, mic: talking, settings: off) == [.restore], "pausing hush restores the volume")
    }

    // MARK: classifier on real audio, through the same streaming path the app uses

    private static func classify(_ path: String) {
        print("classifier · \((path as NSString).lastPathComponent)")
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { check(false, "open \(path)"); return }
        let fmt = file.processingFormat
        guard let classifier = try? SoundClassifier(sampleRate: fmt.sampleRate, label: "test") else { check(false, "make classifier"); return }
        var results: [Heard] = []
        let lock = NSLock()
        classifier.onHeard = { h in lock.lock(); results.append(h); lock.unlock() }
        let chunk: AVAudioFrameCount = 4096
        let started = Date()
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
            try? file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            if let (mono, rms) = AudioMath.monoCopy(buf, into: classifier.format) { classifier.feed(mono, rms: rms) }
        }
        classifier.stop()
        let secs = Double(file.length) / fmt.sampleRate
        let took = Date().timeIntervalSince(started)
        lock.lock(); let r = results; lock.unlock()
        let avg = { (k: KeyPath<Heard, Double>) in r.isEmpty ? 0 : r.map { $0[keyPath: k] }.reduce(0, +) / Double(r.count) }
        print(String(format: "  info  %d windows · speech %.2f · music %.2f · singing %.2f · %.1f s audio in %.2f s (%.0fx realtime)",
                     r.count, avg(\.speech), avg(\.music), avg(\.singing), secs, took, secs / max(took, 0.001)))
    }

    private static func heardStream(_ path: String) -> [Heard] {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let classifier = try? SoundClassifier(sampleRate: file.processingFormat.sampleRate, label: "sim") else { return [] }
        var results: [Heard] = []
        let lock = NSLock()
        classifier.onHeard = { h in lock.lock(); results.append(h); lock.unlock() }
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try? file.read(into: buf, frameCount: 4096)
            if buf.frameLength == 0 { break }
            if let (mono, rms) = AudioMath.monoCopy(buf, into: classifier.format) { classifier.feed(mono, rms: rms) }
        }
        classifier.stop()
        lock.lock(); defer { lock.unlock() }
        return results.sorted { $0.time < $1.time }
    }

    /// End to end: system output file + mic file -> classifier -> decision engine, in simulated real time.
    private static func simulate(system: String, mic: String) {
        print("end to end · output \((system as NSString).lastPathComponent) · mic \((mic as NSString).lastPathComponent)")
        let sys = heardStream(system), room = heardStream(mic)
        var e = DecisionEngine()
        var t = 0.0
        let end = min(sys.last?.time ?? 0, room.last?.time ?? 0) + 6
        var events: [(Double, Action)] = []
        while t < end {
            let s = sys.last { $0.time <= t }.map { t - $0.time < 1.5 ? $0 : Heard(level: -120) }
            let m = room.last { $0.time <= t }.map { t - $0.time < 1.5 ? $0 : Heard(level: -120) }
            let a = e.step(dt: 0.1, system: s, mic: m, volume: 0.5, settings: DuckSettings())
            if a != .none { events.append((t, a)) }
            t += 0.1
        }
        for (t, a) in events { print(String(format: "  info  %5.1f s  %@", t, a == .duck ? "duck" : "restore")) }
        lastEvents = events
    }
    static var lastEvents: [(Double, Action)] = []

    // MARK: snapshots of the panel

    private static func snapshot(to dir: String) {
        print("panel snapshots")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, PanelState)] = [
            ("listening", PanelState(phase: .listening, music: 0.82, voice: 0.12, threshold: 0.55, volume: 0.62, duckedFrom: nil, problem: nil, micName: "macbook pro microphone", ducks: 3)),
            ("ducked", PanelState(phase: .ducked, music: 0.78, voice: 0.91, threshold: 0.55, volume: 0.19, duckedFrom: 0.62, problem: nil, micName: "macbook pro microphone", ducks: 4)),
            ("problem", PanelState(phase: .quiet, music: 0, voice: 0, threshold: 0.55, volume: 0.5, duckedFrom: nil, problem: "can't hear what's playing. allow it in system settings › privacy › screen & system audio recording.", micName: "", ducks: 0)),
        ]
        for (name, state) in states {
            let view = PanelBody(state: state, settings: .constant(DuckSettings()), preferBuiltInMic: .constant(true),
                                 opensAtLogin: .constant(false), quit: {})
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { check(false, "render \(name)"); continue }
            let path = (dir as NSString).appendingPathComponent("panel-\(name).png")
            check((try? png.write(to: URL(fileURLWithPath: path))) != nil, "wrote \(path)")
        }
    }
}
