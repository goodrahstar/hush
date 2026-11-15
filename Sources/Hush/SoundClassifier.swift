import AVFoundation
import SoundAnalysis

/// What the on-device classifier heard in one window of audio.
struct Heard {
    var speech: Double = 0   // a person talking
    var music: Double = 0    // music, instruments or singing
    var singing: Double = 0  // sung vocals (helps tell song lyrics from a real voice)
    var level: Double = -120 // loudness of the window, dBFS
    var time: Double = 0     // end of the window, seconds since the stream started
}

/// Wraps Apple's built-in sound classifier (SoundAnalysis, ~300 labels, runs on device).
/// Feed it mono float buffers; it calls `onHeard` a few times a second with calibrated confidences.
final class SoundClassifier: NSObject, SNResultsObserving {
    static let speechLabels: Set<String> = ["speech", "shout", "yell", "whispering", "chatter",
                                            "laughter", "giggling", "chuckle_chortle", "babble"]
    static let singingLabels: Set<String> = ["singing", "choir_singing", "rapping", "humming", "yodeling"]
    static let musicLabels: Set<String> = [
        "music", "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
        "keyboard_musical", "piano", "electric_piano", "organ", "synthesizer", "percussion", "drum_kit",
        "drum", "snare_drum", "bass_drum", "cymbal", "hi_hat", "orchestra", "brass_instrument", "trumpet",
        "bowed_string_instrument", "violin_fiddle", "cello", "wind_instrument", "flute", "saxophone",
        "harp", "disc_scratching", "singing", "choir_singing", "rapping",
    ]

    let format: AVAudioFormat
    var onHeard: ((Heard) -> Void)?

    private let analyzer: SNAudioStreamAnalyzer
    private let queue: DispatchQueue
    private var position: AVAudioFramePosition = 0
    private(set) var buffersFed = 0
    private(set) var windowsHeard = 0
    private var levelSum: Double = 0
    private var levelCount: Int = 0
    private let lock = NSLock()

    init(sampleRate: Double, label: String, window: Double = 1.0, overlap: Double = 0.75) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        analyzer = SNAudioStreamAnalyzer(format: format)
        queue = DispatchQueue(label: "hush.classifier.\(label)", qos: .userInitiated)
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: window, preferredTimescale: 48_000)
        request.overlapFactor = overlap
        try analyzer.add(request, withObserver: self)
    }

    /// Takes ownership of a mono buffer in `format`. Safe to call from a realtime-ish audio thread.
    func feed(_ buffer: AVAudioPCMBuffer, rms: Float) {
        let db = 20 * log10(Double(max(rms, 1e-6)))
        buffersFed += 1
        queue.async {
            self.lock.lock(); self.levelSum += db; self.levelCount += 1; self.lock.unlock()
            self.analyzer.analyze(buffer, atAudioFramePosition: self.position)
            self.position += AVAudioFramePosition(buffer.frameLength)
        }
    }

    func stop() {
        queue.sync { analyzer.completeAnalysis() }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        windowsHeard += 1
        var heard = Heard()
        heard.time = result.timeRange.end.seconds
        for c in result.classifications {
            let id = c.identifier
            if Self.speechLabels.contains(id) { heard.speech = max(heard.speech, c.confidence) }
            if Self.singingLabels.contains(id) { heard.singing = max(heard.singing, c.confidence) }
            if Self.musicLabels.contains(id) { heard.music = max(heard.music, c.confidence) }
        }
        lock.lock()
        heard.level = levelCount > 0 ? levelSum / Double(levelCount) : -120
        levelSum = 0; levelCount = 0
        lock.unlock()
        onHeard?(heard)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        NSLog("hush: classifier failed: \(error.localizedDescription)")
    }
}

enum AudioMath {
    /// Down-mixes any float32 buffer (interleaved or not) into a new, owned mono buffer. Returns RMS too.
    static func monoCopy(_ src: AVAudioPCMBuffer, into format: AVAudioFormat) -> (AVAudioPCMBuffer, Float)? {
        guard src.format.commonFormat == .pcmFormatFloat32, let channels = src.floatChannelData else { return nil }
        let frames = Int(src.frameLength)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let dst = out.floatChannelData![0]
        let cc = Int(src.format.channelCount)
        let scale = 1 / Float(max(cc, 1))
        var sum: Float = 0
        if src.format.isInterleaved {
            let p = channels[0]
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<cc { s += p[i * cc + c] }
                s *= scale; dst[i] = s; sum += s * s
            }
        } else {
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<cc { s += channels[c][i] }
                s *= scale; dst[i] = s; sum += s * s
            }
        }
        return (out, (sum / Float(frames)).squareRoot())
    }
}
