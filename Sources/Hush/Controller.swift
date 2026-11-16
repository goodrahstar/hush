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

    private var engine = DecisionEngine()
    private let tap = SystemAudioTap()
    private let mic = MicListener()
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
        mic.onHeard = { [weak self] h in Task { @MainActor in self?.lastMic = (h, Date()) } }
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
        defaults.removeObject(forKey: "savedVolume")
        tap.stop(); mic.stop()
    }

    /// Off means off: the mic and the system listener are fully released, so the mic light goes out.
    private func applyEnabled() {
        if settings.enabled {
            log("turned on: listening again")
            startTap()
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { restartMic() }
        } else {
            log("turned off: mic and system listening stopped")
            tap.stop(); mic.stop()
            lastSystem = nil; lastMic = nil
            micName = ""
        }
    }

    private func startTap() {
        guard settings.enabled else { return }
        do { try tap.start(); if problem?.hasPrefix("can't hear") == true { problem = nil } }
        catch { log("tap error \(error)"); problem = "can't hear what's playing: \(error.localizedDescription). allow it in system settings › privacy › screen & system audio recording." }
    }

    private func restartMic() {
        guard settings.enabled else { mic.stop(); return }
        do { try mic.start(preferBuiltIn: preferBuiltInMic); micName = mic.deviceName.lowercased() }
        catch { log("mic error \(error)"); problem = "can't use the microphone: \(error.localizedDescription)" }
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
                self.engine = DecisionEngine()
                self.startTap()
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
        let action = engine.step(dt: 0.1, system: sys, mic: room, volume: userVolume, settings: settings)
        switch action {
        case .duck: duck(from: current)
        case .restore: restore()
        case .none: break
        }

        logStatus(sys: sys, room: room, volume: current)
        phase = engine.phase
        music = engine.music
        voice = engine.voice
        threshold = engine.threshold(settings)
        volume = current
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
        log(String(format: "%@ | out[%@] mic[%@] | music %.2f outVoice %.2f voice %.2f thr %.2f base %.2f vol %.2f tap %@ mic %@",
                   "\(engine.phase)", f(sys), f(room), engine.music, engine.outputVoice, engine.voice,
                   engine.threshold(settings), engine.baseline, volume,
                   tapRunning ? "on(\(tap.classifier?.buffersFed ?? 0)/\(tap.classifier?.windowsHeard ?? 0))" : "off",
                   micRunning ? "on(\(mic.classifier?.buffersFed ?? 0)/\(mic.classifier?.windowsHeard ?? 0))" : "off"))
    }
    private var tapRunning: Bool { tap.running }
    private var micRunning: Bool { mic.running }

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
