import AVFoundation
import Foundation

/// Voice processing (echo cancellation) silences Core Audio process taps in the same process, so the
/// echo-cancelled mic runs in a child process: `Hush --ec-helper`. It classifies on its own and writes one
/// line per result to stdout: `speech music singing level time`. It exits when the parent goes away,
/// when stdin closes, or when the audio hardware changes (the parent restarts it).
enum EchoHelper {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let parent = getppid()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "echo-cancelled mic for hush")
        let mic = EchoCancelledMic()
        mic.onHeard = { h in
            print(String(format: "%.4f %.4f %.4f %.1f %.3f", h.speech, h.music, h.singing, h.level, h.time))
        }
        mic.onConfigurationChange = { fputs("audio hardware changed\n", stderr); exit(2) }
        do { try mic.start() } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
        // Leave when the parent does: stdin hits EOF when Hush closes the pipe or dies.
        Thread.detachNewThread {
            while let _ = readLine() {}
            exit(0)
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { if getppid() != parent { exit(0) } }
        watchdog.resume()
        withExtendedLifetime((activity, mic, watchdog)) { RunLoop.main.run() }
        exit(0)
    }
}

/// The parent's handle on the helper: same shape as the other mics.
final class EchoCancelledMicProcess {
    var onHeard: ((Heard) -> Void)?
    /// The helper exited on its own (hardware change or failure). Called on an arbitrary thread.
    var onUnexpectedExit: ((Int32, String) -> Void)?
    private(set) var deviceName = ""
    private(set) var linesHeard = 0
    var running: Bool { process?.isRunning ?? false }
    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private let lock = NSLock()

    /// Starts the helper and waits (up to 4 s) for its first result, so a failure surfaces here.
    func start() throws {
        stop()
        guard let exe = Bundle.main.executableURL else { throw HushError.message("can't find hush's own executable") }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--ec-helper"]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let firstLine = DispatchSemaphore(value: 0)
        var gotFirst = false
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); self.buffer.append(data)
            var lines: [String] = []
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: self.buffer[self.buffer.startIndex..<nl], as: UTF8.self))
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
            }
            self.lock.unlock()
            for line in lines {
                let f = line.split(separator: " ").compactMap { Double($0) }
                guard f.count == 5 else { continue }
                self.linesHeard += 1
                if !gotFirst { gotFirst = true; firstLine.signal() }
                self.onHeard?(Heard(speech: f[0], music: f[1], singing: f[2], level: f[3], time: f[4]))
            }
        }
        var errText = ""
        err.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8) { errText += s }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self, self.process === proc else { return } // stopped on purpose
            self.onUnexpectedExit?(proc.terminationStatus, errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try p.run()
        process = p; stdinPipe = inp
        deviceName = CA.name(CA.defaultInputDevice)
        if firstLine.wait(timeout: .now() + 4) == .timedOut {
            let msg = errText.isEmpty ? "no audio from the echo-cancelled mic" : errText
            stop()
            throw HushError.message(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        lock.lock(); buffer.removeAll(); lock.unlock()
    }

    deinit { stop() }
}
