import CoreAudio
import Foundation

/// AirPods send motion only to the device they are playing for, so they must be the output.
enum AudioRoute {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func devices() -> [AudioDeviceID] {
        var request = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &request, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &request, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func name(of device: AudioDeviceID) -> String {
        var request = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &request, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var request = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &request, 0, nil, &size) == noErr && size > 0
    }

    private static var currentOutput: AudioDeviceID {
        var request = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &request, 0, nil, &size, &id)
        return id
    }

    private static func isAirPods(_ device: AudioDeviceID) -> Bool {
        name(of: device).localizedCaseInsensitiveContains("AirPods")
    }

    static var isUsingAirPods: Bool { isAirPods(currentOutput) }

    /// Makes the connected AirPods the output, as if chosen in Control Center.
    @discardableResult static func useAirPods() -> Bool {
        guard var id = devices().first(where: { isAirPods($0) && hasOutput($0) }) else { return false }
        var request = address(kAudioHardwarePropertyDefaultOutputDevice)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &request, 0, nil, size, &id) == noErr
    }
}
