import AVFoundation
import CoreAudio
import Foundation

/// Listens to everything the Mac is playing, using a Core Audio process tap (macOS 14.4+).
/// The tap sits before the output volume, so the music still "sounds" the same to us while it is ducked.
final class SystemAudioTap {
    var onHeard: ((Heard) -> Void)?
    private(set) var running = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var classifier: SoundClassifier?
    private let ioQueue = DispatchQueue(label: "hush.tap.io", qos: .userInitiated)

    func start() throws {
        stop()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Hush system listener"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw HushError.coreAudio("create system audio tap", status) }
        tapID = tap

        guard var asbd = CA.get(tapID, CA.address(kAudioTapPropertyFormat), AudioStreamBasicDescription()),
              let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw HushError.message("could not read the tap's audio format")
        }

        let outputUID = CA.getString(CA.defaultOutputDevice, kAudioDevicePropertyDeviceUID) ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hush tap",
            kAudioAggregateDeviceUIDKey: "com.rahulkumar.hush.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { stop(); throw HushError.coreAudio("create listening device", status) }
        aggregateID = agg

        let classifier = try SoundClassifier(sampleRate: tapFormat.sampleRate, label: "system")
        classifier.onHeard = { [weak self] in self?.onHeard?($0) }
        self.classifier = classifier
        let mono = classifier.format

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, input, _, _, _ in
            guard let src = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                  let (buffer, rms) = AudioMath.monoCopy(src, into: mono) else { return }
            classifier.feed(buffer, rms: rms)
        }
        guard status == noErr, let proc else { stop(); throw HushError.coreAudio("attach to listening device", status) }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { stop(); throw HushError.coreAudio("start system listening", status) }
        running = true
    }

    func stop() {
        running = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        classifier = nil
    }

    deinit { stop() }
}

/// Listens to the microphone for people talking. Reads the input device directly with a Core Audio
/// IOProc (AVAudioEngine stalls the main queue when pointed at a non-default input device).
final class MicListener {
    var onHeard: ((Heard) -> Void)?
    private(set) var deviceName = ""
    private(set) var running = false
    private(set) var classifier: SoundClassifier?
    private var device = AudioDeviceID(0)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "hush.mic.io", qos: .userInitiated)

    func start(preferBuiltIn: Bool) throws {
        stop()
        var dev = CA.defaultInputDevice
        if preferBuiltIn, let builtIn = CA.builtInMicrophone { dev = builtIn }
        guard dev != 0, CA.hasInput(dev) else { throw HushError.message("no microphone available") }
        deviceName = CA.name(dev)

        guard var asbd = CA.get(dev, CA.address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput),
                                AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw HushError.message("could not read the microphone's format")
        }
        let classifier = try SoundClassifier(sampleRate: format.sampleRate, label: "mic")
        classifier.onHeard = { [weak self] in self?.onHeard?($0) }
        let mono = classifier.format
        let buffersPerStream = format.isInterleaved ? 1 : Int(format.channelCount)

        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, ioQueue) { _, input, _, _, _ in
            // Only the first input stream: rebuild a list holding just its buffers.
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard all.count >= buffersPerStream else { return }
            let list = AudioBufferList.allocate(maximumBuffers: buffersPerStream)
            defer { free(list.unsafeMutablePointer) }
            for i in 0..<buffersPerStream { list[i] = all[i] }
            guard let src = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil),
                  let (buffer, rms) = AudioMath.monoCopy(src, into: mono) else { return }
            classifier.feed(buffer, rms: rms)
        }
        guard status == noErr, let proc else { throw HushError.coreAudio("attach to the microphone", status) }
        status = AudioDeviceStart(dev, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(dev, proc)
            throw HushError.coreAudio("start the microphone", status)
        }
        device = dev; procID = proc
        self.classifier = classifier
        running = true
    }

    func stop() {
        running = false
        if let procID, device != 0 {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        device = 0
        classifier = nil
    }

    deinit { stop() }
}

/// The mic with Apple's voice processing on: echo cancellation removes what the Mac's own speakers
/// play, so a podcast on the speakers doesn't sound like someone in the room. Measured on a MacBook Pro
/// at 50% volume: speaker leak drops from −32 dB to −59 dB and its speech score from 0.90 to 0.09.
/// It always uses the default input device (voice processing has no device choice), and it's only used
/// while spoken content plays on speakers.
final class EchoCancelledMic {
    var onHeard: ((Heard) -> Void)?
    /// Called (on an arbitrary thread) when the audio hardware changes under the engine.
    var onConfigurationChange: (() -> Void)?
    private(set) var deviceName = ""
    private(set) var running = false
    private(set) var classifier: SoundClassifier?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Don't turn other apps down while we listen (voice processing ducks other audio by default).
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        input.isVoiceProcessingAGCEnabled = false

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw HushError.message("echo-cancelled mic has no audio") }
        let classifier = try SoundClassifier(sampleRate: format.sampleRate, label: "mic-ec")
        classifier.onHeard = { [weak self] in self?.onHeard?($0) }
        let mono = classifier.format

        // Channel 0 is the processed (echo-cancelled) voice; the other channels are raw mics. Never mix them in.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            let frames = Int(buf.frameLength)
            guard frames > 0, let src = buf.floatChannelData?[0],
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return }
            out.frameLength = AVAudioFrameCount(frames)
            let dst = out.floatChannelData![0]
            var sum: Float = 0
            for i in 0..<frames { let s = src[i]; dst[i] = s; sum += s * s }
            classifier.feed(out, rms: (sum / Float(frames)).squareRoot())
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in self?.onConfigurationChange?() }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw HushError.message("could not start the echo-cancelled mic: \(error.localizedDescription)")
        }
        self.engine = engine
        self.classifier = classifier
        deviceName = CA.name(CA.defaultInputDevice)
        running = true
    }

    func stop() {
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine = nil
        classifier = nil
    }

    deinit { stop() }
}

enum HushError: LocalizedError {
    case coreAudio(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(what, status): return "could not \(what) (error \(status))"
        case let .message(m): return m
        }
    }
}
