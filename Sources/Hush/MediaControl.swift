import Foundation

/// Pauses and resumes whatever app is the Mac's "Now Playing" app (Music, Spotify, Podcasts, QuickTime,
/// YouTube in Safari or Chrome...) through MediaRemote, the private framework behind the media keys and
/// Control Center. Sending commands still works on macOS 15; reading the playing state does not, so Hush
/// checks the result by listening to the output instead.
enum MediaControl {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let play: UInt32 = 0  // kMRPlay
    private static let pause: UInt32 = 1 // kMRPause

    private static let send: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    static var available: Bool { send != nil }

    /// Explicit pause, never a toggle: if nothing is playing, nothing starts.
    @discardableResult static func pausePlayback() -> Bool { send?(pause, nil) ?? false }

    /// Explicit play. Only call it for something Hush paused itself.
    @discardableResult static func resumePlayback() -> Bool { send?(play, nil) ?? false }
}
