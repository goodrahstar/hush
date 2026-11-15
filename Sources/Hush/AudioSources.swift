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
