import AudioToolbox
import CoreAudio
import Foundation

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static var defaultOutputDevice: AudioDeviceID {
        Self.get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
    }

    static var defaultInputDevice: AudioDeviceID {
        Self.get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)) ?? 0
    }

    static func allDevices() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr && size > 0
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        get(device, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    }

    /// The Mac's own microphone. Using it instead of AirPods' mic keeps Bluetooth headphones in
    /// high-quality stereo; opening a Bluetooth mic drops them into low-quality call mode.
    static var builtInMicrophone: AudioDeviceID? {
        allDevices().first { hasInput($0) && transport($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Whether what this output plays reaches the room (and the mic). Headphones don't; speakers do.
    /// Bluetooth is assumed to be headphones (AirPods); the built-in output counts as headphones when
    /// something is plugged into the jack.
    static func outputReachesRoom(_ device: AudioDeviceID) -> Bool {
        if isBluetooth(device) { return false }
        if transport(device) == kAudioDeviceTransportTypeBuiltIn,
           let source = get(device, address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), UInt32(0)),
           source == 0x6864_706E /* 'hdpn' */ {
            return false
        }
        let n = name(device).lowercased()
        return !(n.contains("headphone") || n.contains("airpods") || n.contains("buds"))
    }

    static func name(_ device: AudioDeviceID) -> String {
        getString(device, kAudioObjectPropertyName) ?? "unknown device"
    }
}

/// Reads and writes the system output volume (the one the volume keys change).
enum SystemVolume {
    private static let mainVolume = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                               kAudioDevicePropertyScopeOutput)

    static func get(_ device: AudioDeviceID = CA.defaultOutputDevice) -> Float? {
        if let v = CA.get(device, mainVolume, Float32(0)) { return v }
        // Fallback: average the left/right channel scalars.
        let vals = [UInt32(1), 2].compactMap {
            CA.get(device, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0), Float32(0))
        }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
    }

    @discardableResult
    static func set(_ value: Float, _ device: AudioDeviceID = CA.defaultOutputDevice) -> Bool {
        var v = Float32(min(max(value, 0), 1))
        var a = mainVolume
        if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { return true }
        var ok = false
        for ch in [UInt32(1), 2] {
            var ca = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
            if AudioObjectSetPropertyData(device, &ca, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { ok = true }
        }
        return ok
    }

    static func isMuted(_ device: AudioDeviceID = CA.defaultOutputDevice) -> Bool {
        (CA.get(device, CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(0)) ?? 0) != 0
    }

    static func canSet(_ device: AudioDeviceID = CA.defaultOutputDevice) -> Bool {
        var a = mainVolume
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }
}
