import AVFoundation
import CoreAudio
import Foundation
import ServiceManagement

@MainActor
final class Controller: ObservableObject {
    static let shared = Controller()

    @Published var settings: DuckSettings { didSet { save(); if settings.enabled != oldValue.enabled { applyEnabled() } } }
    @Published var preferBuiltInMic: Bool { didSet { UserDefaults.standard.set(preferBuiltInMic, forKey: "preferBuiltInMic"); restartMic() } }
    @Published private(set) var phase: Phase = .quiet
    @Published private(set) var music = 0.0
    @Published private(set) var voice = 0.0
    @Published private(set) var threshold = 0.55
    @Published private(set) var volume = 0.0
    @Published private(set) var duckedFrom: Double?
    @Published private(set) var problem: String?
    @Published private(set) var micName = ""
    @Published private(set) var ducksToday = 0
    @Published private(set) var pausesToday = 0
    @Published private(set) var content: Content = .none
    @Published private(set) var talk = 0.0
    @Published private(set) var echoCancelling = false

    private var engine = DecisionEngine()
    private let tap = SystemAudioTap()
    private let mic = MicListener()
    private let ecMic = EchoCancelledMicProcess() // a child process: voice processing silences taps in-process
    /// Echo cancellation is used only while spoken content plays on speakers; plain mic otherwise.
    private var wantEchoCancel = false
    private var notTalkFor = 0.0
    private var outputLeaks = true
    private var ignoreMicUntil = Date.distantPast
    private var ecSettling = false
    private var micStarting = false
    private var micDownFor = 0.0
    private var lastSystem: (Heard, Date)?
    private var lastMic: (Heard, Date)?
    private var timer: DispatchSourceTimer?
    private var ramp: Task<Void, Never>?
    private var lastWritten: Float?
    private var duckedDevice = AudioDeviceID(0)
    private var userTookOver = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let defaults = UserDefaults.standard

    private init() {
        var s = DuckSettings()
        let d = UserDefaults.standard
        if d.object(forKey: "enabled") != nil { s.enabled = d.bool(forKey: "enabled") }
        if d.object(forKey: "duckTo") != nil { s.duckTo = d.double(forKey: "duckTo") }
        if d.object(forKey: "sensitivity") != nil { s.sensitivity = d.double(forKey: "sensitivity") }
        if d.object(forKey: "holdSeconds") != nil { s.holdSeconds = d.double(forKey: "holdSeconds") }
        if d.object(forKey: "pauseTalk") != nil { s.pauseTalk = d.bool(forKey: "pauseTalk") }
        settings = s
        preferBuiltInMic = d.object(forKey: "preferBuiltInMic") == nil ? true : d.bool(forKey: "preferBuiltInMic")
    }

    // MARK: lifecycle

    private var activity: NSObjectProtocol?

    func start() {
        log("hush started")
        // A menu bar app with no window gets App Nap'd: timers slow to a crawl. Hush must react in real time.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "listening for voices over music")
        recoverFromCrash()
        tap.onHeard = { [weak self] h in Task { @MainActor in self?.lastSystem = (h, Date()) } }
        mic.onHeard = { [weak self] h in Task { @MainActor in self?.heardMic(h, echoCancelled: false) } }
        ecMic.onHeard = { [weak self] h in Task { @MainActor in self?.heardMic(h, echoCancelled: true) } }
        ecMic.onUnexpectedExit = { [weak self] status, why in
            Task { @MainActor in
                guard let self, self.echoCancelling else { return }
                self.log("echo-cancelled mic stopped (\(status): \(why)), restarting")
                self.restartMic()
            }
        }
        outputLeaks = CA.outputReachesRoom(CA.defaultOutputDevice)
        log("output \(CA.name(CA.defaultOutputDevice)) reaches the room: \(outputLeaks) · media control: \(MediaControl.available)")
        if settings.enabled { startTap() } else { log("off at launch: not listening") }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.log("mic permission granted=\(granted)")
                if granted { self.restartMic() } else { self.problem = "microphone access is off. turn it on in system settings › privacy › microphone." }
            }
        }
        watchOutputDevice()
        // A dispatch timer on the main queue keeps firing while the menu panel is open
        // (a plain Timer in default run-loop mode pauses during UI tracking).
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    func shutdown() {
        timer?.cancel()
        if let from = duckedFrom, !userTookOver { SystemVolume.set(Float(from), duckedDevice != 0 ? duckedDevice : CA.defaultOutputDevice) }
        if engine.phase == .paused { resumePlayback(reason: "hush quit") }
        defaults.removeObject(forKey: "savedVolume")
        let tap = self.tap, mic = self.mic, ecMic = self.ecMic
        audioQueue.sync { tap.stop(); mic.stop(); ecMic.stop() }
    }

    /// Off means off: the mic and the system listener are fully released, so the mic light goes out.
    private func applyEnabled() {
        if settings.enabled {
            log("turned on: listening again")
            startTap()
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { restartMic() }
        } else {
            log("turned off: mic and system listening stopped")
            let tap = self.tap, mic = self.mic, ecMic = self.ecMic
            audioQueue.async { tap.stop(); mic.stop(); ecMic.stop() }
            lastSystem = nil; lastMic = nil
            micName = ""; echoCancelling = false
        }
    }

    // Core Audio start/stop can block for a long time (the HAL waits on device changes),
    // so it never runs on the main thread: the menu must stay responsive.
    private let audioQueue = DispatchQueue(label: "hush.audio.control", qos: .userInitiated)

    private func startTap() {
        guard settings.enabled else { return }
        let tap = self.tap, queue = audioQueue
        queue.async { [weak self] in
            let t0 = Date()
            var failure: Error?
            do { try tap.start() } catch { failure = error }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.log("tap error \(failure)")
                    self.problem = "can't hear what's playing: \(failure.localizedDescription). allow it in system settings › privacy › screen & system audio recording."
                } else {
                    self.log("system listening started in \(ms) ms")
                    if self.problem?.hasPrefix("can't hear") == true { self.problem = nil }
                    if !self.settings.enabled { queue.async { tap.stop() } } // switched off while starting
                }
            }
        }
    }

    /// Starts the right mic for the moment: echo-cancelled while spoken content plays on speakers
    /// (and the default input is the mic we'd use anyway), the plain mic otherwise. Only one runs at a time.
    private func restartMic() {
        let useEC = wantEchoCancel && settings.enabled && outputLeaks && ecMicMatchesPreferred
        let mic = self.mic, ecMic = self.ecMic, queue = audioQueue
        let enabled = settings.enabled, preferBuiltIn = preferBuiltInMic
        micStarting = true
        lastMic = nil
        ecSettling = false
        ignoreMicUntil = useEC ? .distantFuture : Date().addingTimeInterval(0.5) // EC: set from its first result
        queue.async { [weak self] in
            guard enabled else { mic.stop(); ecMic.stop(); return }
            let t0 = Date()
            var failure: Error?
            // Right after voice processing lets go of the mic, the device can refuse to start for a moment.
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.6) }
                failure = nil
                if useEC {
                    mic.stop()
                    do { try ecMic.start() } catch { failure = error }
                } else {
                    ecMic.stop()
                    do { try mic.start(preferBuiltIn: preferBuiltIn) } catch { failure = error }
                }
                if failure == nil { break }
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let name = (useEC ? ecMic.deviceName : mic.deviceName).lowercased()
            DispatchQueue.main.async {
                guard let self else { return }
                self.micStarting = false
                if let failure {
                    self.echoCancelling = false
                    self.log("mic error (\(useEC ? "echo-cancelled" : "plain")) \(failure)")
                    if useEC {
                        // Fall back to the plain mic; talk detection just won't work over speakers.
                        self.wantEchoCancel = false
                        self.restartMic()
                    } else {
                        self.problem = "can't use the microphone: \(failure.localizedDescription)"
                    }
                } else if self.settings.enabled {
                    self.log("\(useEC ? "echo-cancelled" : "plain") mic started in \(ms) ms (\(name))")
                    if self.problem?.hasPrefix("can't use the microphone") == true { self.problem = nil }
                    self.micName = name
                    self.echoCancelling = useEC
                } else {
                    queue.async { mic.stop(); ecMic.stop() } // switched off while starting
                }
            }
        }
    }

    /// Voice processing always uses the default input. Use it only if that is the mic Hush would pick.
    private var ecMicMatchesPreferred: Bool {
        guard preferBuiltInMic, let builtIn = CA.builtInMicrophone else { return true }
        return CA.defaultInputDevice == builtIn
    }

    private func heardMic(_ h: Heard, echoCancelled: Bool) {
        guard echoCancelled == echoCancelling else { return }
        // Echo cancellation needs ~2.5 s of playback to converge (measured), counted from its first result.
        if echoCancelled && !ecSettling { ecSettling = true; ignoreMicUntil = Date().addingTimeInterval(3) }
        guard Date() >= ignoreMicUntil else { return }
        lastMic = (h, Date())
    }

    private func watchOutputDevice() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Headphones in or out: put the old device back first, then listen to the new one.
                self.ramp?.cancel()
                if let from = self.duckedFrom, !self.userTookOver, self.duckedDevice != 0 {
                    SystemVolume.set(Float(from), self.duckedDevice)
                    self.log("output changed while ducked: restored \(CA.name(self.duckedDevice)) to \(from)")
                }
                self.duckedFrom = nil; self.userTookOver = false
                self.defaults.removeObject(forKey: "savedVolume")
                if self.engine.phase == .paused { self.resumePlayback(reason: "output changed") }
                self.engine = DecisionEngine()
                self.outputLeaks = CA.outputReachesRoom(CA.defaultOutputDevice)
                self.log("output now \(CA.name(CA.defaultOutputDevice)), reaches the room: \(self.outputLeaks)")
                self.startTap()
                self.updateMicPath(force: true)
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    // MARK: the loop


    private func tick() {
        let now = Date()
        let sys = lastSystem.flatMap { now.timeIntervalSince($0.1) < 1.5 ? $0.0 : nil }
        let room = lastMic.flatMap { now.timeIntervalSince($0.1) < 1.5 ? $0.0 : nil }
        let current = Double(SystemVolume.get() ?? 0)
        let muted = SystemVolume.isMuted()

        // The user moved the volume while we had it ducked: their choice wins, we won't restore over it.
        if let lastWritten, duckedFrom != nil, ramp == nil, abs(Float(current) - lastWritten) > 0.04 {
            userTookOver = true
        }

        let userVolume = muted ? 0 : (duckedFrom ?? current)
        let path: MicPath = !outputLeaks ? .headphones : echoCancelling ? .echoCancelled : .speakersRaw
        let before = engine.phase
        let action = engine.step(dt: 0.1, system: sys, mic: room, volume: userVolume, settings: settings, micPath: path)
        switch action {
        case .duck:
            if before == .paused { log("the player ignored the pause: lowering the volume instead") }
            duck(from: current)
        case .restore: restore()
        case .pause: pausePlayback()
        case .resume: resumePlayback(reason: "room quiet")
        case .none:
            if before == .paused && engine.phase == .listening { log("playback started again by someone else: hush steps back") }
        }
        lastSys = sys
        updateMicPath(force: false)
        micWatchdog()

        logStatus(sys: sys, room: room, volume: current)
        phase = engine.phase
        music = engine.music
        talk = engine.outputSpeech
        content = engine.content
        voice = engine.voice
        threshold = engine.threshold(settings)
        volume = current
    }

    private var lastSys: Heard?

    /// Switch to the echo-cancelled mic while spoken content plays on speakers; back to the plain mic
    /// 15 s after it stops. Never switches mid-action, so a pause or duck always ends on the same mic.
    private func updateMicPath(force: Bool) {
        guard settings.enabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let talkPlaying = settings.pauseTalk && engine.content == .talk && outputLeaks
        // A podcast Hush paused is still "talk": don't count the pause toward switching back.
        notTalkFor = talkPlaying || engine.phase == .paused ? 0 : notTalkFor + 0.1
        let want = talkPlaying ? true : (notTalkFor >= 15 ? false : wantEchoCancel)
        guard force || want != wantEchoCancel else { return }
        guard force || engine.phase == .listening || engine.phase == .quiet else { return }
        wantEchoCancel = want && outputLeaks && settings.pauseTalk
        if force || wantEchoCancel != echoCancelling {
            log(wantEchoCancel ? "spoken content on speakers: switching to the echo-cancelled mic" : "switching back to the plain mic")
            restartMic()
        }
    }

    /// Hush is on but no mic is running (a start failed, or the helper died): try again every 5 s.
    private func micWatchdog() {
        let up = mic.running || ecMic.running
        guard settings.enabled, !up, !micStarting,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { micDownFor = 0; return }
        micDownFor += 0.1
        if micDownFor >= 5 {
            micDownFor = 0
            log("no mic running: starting it again")
            restartMic()
        }
    }

    private func pausePlayback() {
        let ok = MediaControl.pausePlayback()
        pausesToday += 1
        log("someone's talking over spoken content: pause sent (\(ok ? "ok" : "failed"))")
    }

    /// Play again only if the output is still quiet: if someone already pressed play, leave it alone.
    private func resumePlayback(reason: String) {
        let silent = (lastSys?.level ?? -120) <= -65
        guard silent else { log("resume skipped (\(reason)): something is already playing"); return }
        let ok = MediaControl.resumePlayback()
        log("resume sent (\(reason)) (\(ok ? "ok" : "failed"))")
    }

    private func duck(from current: Double) {
        guard SystemVolume.canSet() else { problem = "this output can't change volume from the mac."; return }
        duckedFrom = current
        duckedDevice = CA.defaultOutputDevice
        userTookOver = false
        ducksToday += 1
        defaults.set(current, forKey: "savedVolume")
        let target = max(0.03, current * settings.duckTo)
        rampVolume(to: target, seconds: 0.35)
    }

    private func restore() {
        guard let from = duckedFrom else { return }
        duckedFrom = nil
        defaults.removeObject(forKey: "savedVolume")
        if userTookOver { userTookOver = false; return }
        rampVolume(to: from, seconds: 1.5)
    }

    private func rampVolume(to target: Double, seconds: Double) {
        ramp?.cancel()
        let start = Double(SystemVolume.get() ?? Float(target))
        let steps = max(1, Int(seconds * 40))
        ramp = Task { @MainActor in
            for i in 1...steps {
                if Task.isCancelled { return }
                let t = Double(i) / Double(steps)
                let eased = 1 - pow(1 - t, 3) // ease-out
                let v = Float(start + (target - start) * eased)
                SystemVolume.set(v)
                self.lastWritten = SystemVolume.get() ?? v
                try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1e9))
            }
            self.ramp = nil
        }
    }

    // MARK: status log (~/Library/Logs/Hush.log), one line a second, for tuning and debugging

    private var logTicks = 0
    private lazy var logHandle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hush.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
    }()

    func log(_ line: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        logHandle?.write("\(ts) \(line)\n".data(using: .utf8)!)
    }

    private func logStatus(sys: Heard?, room: Heard?, volume: Double) {
        if engine.phase != phase { log("phase \(phase) -> \(engine.phase)") }
        logTicks += 1
        guard logTicks % 10 == 0 else { return }
        func f(_ h: Heard?) -> String {
            guard let h else { return "none" }
            return String(format: "speech %.2f music %.2f sing %.2f level %.0fdB", h.speech, h.music, h.singing, h.level)
        }
        log(String(format: "%@ %@%@ | out[%@] mic[%@] | music %.2f outVoice %.2f voice %.2f thr %.2f base %.2f vol %.2f tap %@ mic %@",
                   "\(engine.phase)", "\(engine.content)", echoCancelling ? " ec" : "", f(sys), f(room), engine.music, engine.outputVoice, engine.voice,
                   engine.threshold(settings), engine.baseline, volume,
                   tapRunning ? "on(\(tap.classifier?.buffersFed ?? 0)/\(tap.classifier?.windowsHeard ?? 0))" : "off",
                   micStatus))
    }
    private var tapRunning: Bool { tap.running }
    private var micStatus: String {
        if ecMic.running { return "ec(\(ecMic.linesHeard))" }
        if mic.running { return "on(\(mic.classifier?.buffersFed ?? 0)/\(mic.classifier?.windowsHeard ?? 0))" }
        return "off"
    }

    /// If Hush was killed while ducked, put the volume back on next launch.
    private func recoverFromCrash() {
        if defaults.object(forKey: "savedVolume") != nil {
            SystemVolume.set(Float(defaults.double(forKey: "savedVolume")))
            defaults.removeObject(forKey: "savedVolume")
        }
    }

    private func save() {
        defaults.set(settings.enabled, forKey: "enabled")
        defaults.set(settings.duckTo, forKey: "duckTo")
        defaults.set(settings.sensitivity, forKey: "sensitivity")
        defaults.set(settings.holdSeconds, forKey: "holdSeconds")
        defaults.set(settings.pauseTalk, forKey: "pauseTalk")
    }

    // MARK: open at login

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { problem = "couldn't change open at login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }
}
