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
            if args[i] == "--path", i + 1 < args.count {
                simPath = ["raw": .speakersRaw, "ec": .echoCancelled, "headphones": .headphones][args[i + 1]] ?? .echoCancelled; i += 1
            }
            if args[i] == "--tapvp" { tapWithEchoCancel(); }
            if args[i] == "--tapcount" {
                let tap = SystemAudioTap()
                try? tap.start(); RunLoop.main.run(until: Date().addingTimeInterval(3))
                print("  info  tap: \(tap.classifier?.buffersFed ?? 0) buffers in 3 s"); tap.stop()
            }
            if args[i] == "--media", i + 1 < args.count {
                let ok = args[i + 1] == "pause" ? MediaControl.pausePlayback() : MediaControl.resumePlayback()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5)) // the command is delivered asynchronously
                check(MediaControl.available && ok, "media control \(args[i + 1]) sent"); i += 1
            }
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
                             volume: Double = 0.6, settings: DuckSettings = DuckSettings(),
                             path: MicPath = .speakersRaw) -> [Action] {
        var out: [Action] = []
        for _ in 0..<Int((seconds * 10).rounded()) {
            let a = e.step(dt: 0.1, system: sys, mic: mic, volume: volume, settings: settings, micPath: path)
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

        talkScenarios()
    }

    /// Spoken content (podcasts, videos): paused, not ducked. Numbers measured on this Mac:
    /// a podcast scores speech 0.95 / music 0.18 in the output; on speakers at 50% the plain mic hears it
    /// as speech 0.90, the echo-cancelled mic as speech 0.09 at −59 dB.
    private static func talkScenarios() {
        let podcast = h(speech: 0.95, music: 0.18, singing: 0.04, level: -25)
        let silence = h(level: -120)
        let rawLeak = h(speech: 0.90, music: 0.25, level: -32)
        let ecLeak = h(speech: 0.09, music: 0.41, level: -59)
        let person = h(speech: 0.92, music: 0.1, level: -38)
        let quietRoom = h(speech: 0.03, music: 0.05, level: -60)
        let ec = MicPath.echoCancelled

        var e = DecisionEngine()
        _ = play(&e, 3, sys: podcast, mic: ecLeak, path: ec)
        check(e.content == .talk && e.phase == .listening, "a podcast is recognised as spoken content")
        check(play(&e, 30, sys: podcast, mic: ecLeak, path: ec).isEmpty, "podcast leak through the echo-cancelled mic never pauses")
        check(play(&e, 1.5, sys: podcast, mic: person, path: ec) == [.pause], "a person talking over a podcast pauses it within 1.5 s")
        check(play(&e, 2, sys: silence, mic: person, path: ec).isEmpty && e.phase == .paused, "stays paused while they keep talking")
        check(play(&e, 2.0, sys: silence, mic: quietRoom, path: ec).isEmpty, "waits out a short gap in the conversation")
        check(play(&e, 1.0, sys: silence, mic: quietRoom, path: ec) == [.resume], "plays again after the quiet hold")

        // Live: echo cancellation leaves quiet residue the classifier still calls speech (0.4-0.8 at -51..-65 dB).
        e = DecisionEngine()
        _ = play(&e, 5, sys: podcast, mic: ecLeak, path: ec)
        var residue: [Action] = []
        for _ in 0..<10 {
            residue += play(&e, 1, sys: podcast, mic: h(speech: 0.8, music: 0.1, level: -52), path: ec)
            residue += play(&e, 1, sys: podcast, mic: h(speech: 0.4, music: 0.2, level: -56), path: ec)
        }
        check(residue.isEmpty, "quiet echo residue that sounds like speech never pauses")

        e = DecisionEngine()
        check(play(&e, 30, sys: podcast, mic: rawLeak, path: .speakersRaw).isEmpty, "podcast leak into a plain mic on speakers never pauses")

        e = DecisionEngine()
        _ = play(&e, 3, sys: podcast, mic: quietRoom, path: .headphones)
        check(play(&e, 1.5, sys: podcast, mic: person, path: .headphones) == [.pause], "with headphones, a person talking pauses the podcast")

        // The player ignores the pause (output never goes quiet): lower the volume instead.
        e = DecisionEngine()
        _ = play(&e, 3, sys: podcast, mic: ecLeak, path: ec)
        _ = play(&e, 1.5, sys: podcast, mic: person, path: ec)
        check(play(&e, 2.5, sys: podcast, mic: person, path: ec) == [.duck] && e.phase == .ducked, "if the player ignores the pause, hush lowers the volume")

        // Someone presses play while paused: Hush steps back, no resume command.
        e = DecisionEngine()
        _ = play(&e, 3, sys: podcast, mic: ecLeak, path: ec)
        _ = play(&e, 1.5, sys: podcast, mic: person, path: ec)
        _ = play(&e, 1, sys: silence, mic: person, path: ec)
        check(play(&e, 1.5, sys: podcast, mic: person, path: ec).isEmpty && e.phase == .listening, "if someone presses play while paused, hush steps back")
        check(play(&e, 5, sys: podcast, mic: person, path: ec).isEmpty, "and doesn't pause again while the same conversation goes on")
        _ = play(&e, 3, sys: podcast, mic: quietRoom, path: ec)
        check(play(&e, 1.5, sys: podcast, mic: person, path: ec) == [.pause], "after a quiet spell, a new conversation pauses again")

        // Turning hush off while paused plays it again.
        e = DecisionEngine()
        _ = play(&e, 3, sys: podcast, mic: ecLeak, path: ec)
        _ = play(&e, 1.5, sys: podcast, mic: person, path: ec)
        var off = DuckSettings(); off.enabled = false
        check(play(&e, 0.1, sys: silence, mic: person, settings: off, path: ec) == [.resume], "switching hush off while paused plays it again")

        // "pause podcasts and videos" off: spoken content is left alone, music still ducks.
        e = DecisionEngine()
        var noPause = DuckSettings(); noPause.pauseTalk = false
        check(play(&e, 5, sys: podcast, mic: person, settings: noPause, path: ec).isEmpty, "with pausing off, talk over a podcast does nothing")

        // Music with sung vocals stays music: ducked, never paused.
        e = DecisionEngine()
        let vocalSong = h(speech: 0.5, music: 0.8, singing: 0.8)
        _ = play(&e, 3, sys: vocalSong, mic: quietRoom, path: ec)
        check(e.content == .music, "a song with vocals is music, not talk")
        check(play(&e, 1.5, sys: vocalSong, mic: person, path: ec) == [.duck], "talking over a song still ducks it")

        // A podcast with a music bed under the voices is still talk.
        e = DecisionEngine()
        _ = play(&e, 3, sys: h(speech: 0.85, music: 0.5, singing: 0.05, level: -25), mic: quietRoom, path: ec)
        check(e.content == .talk, "a podcast with background music is still spoken content")
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
    static var simPath: MicPath = .echoCancelled
    private static func simulate(system: String, mic: String) {
        print("end to end · output \((system as NSString).lastPathComponent) · mic \((mic as NSString).lastPathComponent)")
        let sys = heardStream(system), room = heardStream(mic)
        var e = DecisionEngine()
        var t = 0.0
        let end = min(sys.last?.time ?? 0, room.last?.time ?? 0) + 6
        var events: [(Double, Action)] = []
        // The output behaves like a player that obeys pause and play: its clock stops while paused.
        var playhead = 0.0, paused = false
        while t < end {
            let s = paused ? Heard(level: -120) : sys.last { $0.time <= playhead }.map { playhead - $0.time < 1.5 ? $0 : Heard(level: -120) }
            let m = room.last { $0.time <= t }.map { t - $0.time < 1.5 ? $0 : Heard(level: -120) }
            let a = e.step(dt: 0.1, system: s, mic: m, volume: 0.5, settings: DuckSettings(), micPath: simPath)
            if a == .pause { paused = true }
            if a == .resume { paused = false }
            if a != .none { events.append((t, a)) }
            if !paused { playhead += 0.1 }
            t += 0.1
        }
        for (t, a) in events { print(String(format: "  event %5.1f s  %@", t, "\(a)")) }
        print("  info  path \(simPath) · \(events.count) event(s)")
        lastEvents = events
    }
    static var lastEvents: [(Double, Action)] = []

    /// Does the system tap keep delivering while the echo-cancelled mic runs? Play something first.
    private static func tapWithEchoCancel() {
        print("system tap with echo cancellation")
        let tap = SystemAudioTap(), ec = EchoCancelledMicProcess()
        func fed() -> Int { tap.classifier?.buffersFed ?? 0 }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        do { try tap.start() } catch { check(false, "tap start \(error)"); return }
        wait(3); let a = fed(); print("  info  tap alone: \(a) buffers in 3 s")
        do { try ec.start() } catch { check(false, "ec start \(error)"); return }
        let b0 = fed(); wait(3); let b = fed() - b0; print("  info  tap with echo-cancelled mic running: \(b) buffers in 3 s")
        let lines = ec.linesHeard
        ec.stop(); tap.stop()
        print("  info  echo-cancelled mic results: \(lines)")
        check(b > a / 2, "the tap keeps delivering while the echo-cancelled mic (helper process) runs")
        check(lines >= 8, "the echo-cancelled mic helper sends results")
    }

    // MARK: snapshots of the panel

    private static func snapshot(to dir: String) {
        print("panel snapshots")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, PanelState)] = [
            ("listening", PanelState(phase: .listening, music: 0.82, voice: 0.12, threshold: 0.55, volume: 0.62, duckedFrom: nil, problem: nil, micName: "macbook pro microphone", ducks: 3)),
            ("ducked", PanelState(phase: .ducked, music: 0.78, voice: 0.91, threshold: 0.55, volume: 0.19, duckedFrom: 0.62, problem: nil, micName: "macbook pro microphone", ducks: 4)),
            ("talk", PanelState(phase: .listening, music: 0.18, voice: 0.05, threshold: 0.55, volume: 0.5, duckedFrom: nil, problem: nil, micName: "macbook pro microphone", ducks: 3, content: .talk, talk: 0.93, pauses: 1, echoCancelling: true)),
            ("paused", PanelState(phase: .paused, music: 0, voice: 0.88, threshold: 0.55, volume: 0.5, duckedFrom: nil, problem: nil, micName: "macbook pro microphone", ducks: 3, content: .none, talk: 0.1, pauses: 2, echoCancelling: true)),
            ("off", PanelState(phase: .off, music: 0.8, voice: 0.1, threshold: 0.55, volume: 0.62, duckedFrom: nil, problem: nil, micName: "macbook pro microphone", ducks: 4)),
            ("problem", PanelState(phase: .quiet, music: 0, voice: 0, threshold: 0.55, volume: 0.5, duckedFrom: nil, problem: "can't hear what's playing. allow it in system settings › privacy › screen & system audio recording.", micName: "", ducks: 0)),
        ]
        for (name, state) in states {
            var st = DuckSettings(); st.enabled = state.phase != .off
            let view = PanelBody(state: state, settings: .constant(st), preferBuiltInMic: .constant(true),
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
