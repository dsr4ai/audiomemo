import AppKit
import CoreAudio
import Foundation

/// 一支輸入裝置（麥克風）。
struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    /// 藍牙麥克風（會讓藍牙切成通話音質）
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}

/// 某個 App 正在用的輸入裝置。
struct InputUsage: Hashable {
    let pid: pid_t
    let bundleID: String
    let deviceID: AudioObjectID
}

/// Core Audio HAL 的薄包裝：列裝置、讀屬性。
enum AudioHAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
        var addr = addr
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func array(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamCount(_ device: AudioObjectID, input: Bool) -> Int {
        array(device, address(kAudioDevicePropertyStreams,
                              input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)).count
    }

    /// 每個輸入 buffer 的聲道數（依 HAL 給 IOProc 的順序）。
    static func inputChannelsPerBuffer(_ device: AudioObjectID) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func defaultDevice(input: Bool) -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject),
            address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(kAudioObjectUnknown))
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func allDevices() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }

    /// 所有可當麥克風的裝置：內建、USB、iPhone 接續互通、藍牙、聚集裝置…（排除本 App 自己臨時建的私有裝置）。
    static func inputDevices() -> [InputDevice] {
        allDevices().compactMap { id in
            guard streamCount(id, input: true) > 0 else { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.bookai.audiomemo") else { return nil }
            let transport: UInt32 = get(id, address(kAudioDevicePropertyTransportType), default: 0)
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return InputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    static func inputDevice(uid: String) -> InputDevice? { inputDevices().first { $0.uid == uid } }

    /// 系統目前的預設輸入裝置。
    static func systemDefaultInput() -> InputDevice? {
        let id = defaultDevice(input: true)
        return inputDevices().first { $0.id == id }
    }

    /// 其他 App 正在收音的輸入裝置（Core Audio process 物件，macOS 14+）。排除本 App 自己。
    static func inputsInUseByOtherApps() -> [InputUsage] {
        let me = getpid()
        return array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyProcessObjectList)).flatMap { proc -> [InputUsage] in
            let running: UInt32 = get(proc, address(kAudioProcessPropertyIsRunningInput), default: 0)
            guard running != 0 else { return [] }
            let pid: pid_t = get(proc, address(kAudioProcessPropertyPID), default: -1)
            guard pid != me, pid > 0 else { return [] }
            let bundle = string(proc, kAudioProcessPropertyBundleID) ?? ""
            let devs = array(proc, address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))
            return devs.map { InputUsage(pid: pid, bundleID: bundle, deviceID: $0) }
        }
    }

    /// 用 bundle ID／pid 找 App 的顯示名稱（例如 zoom.us → Zoom）。
    static func appName(pid: pid_t, bundleID: String) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
    }

    /// 預設麥克風：Mac 內建麥克風（避免 AirPods 麥克風把藍牙切成通話音質）。
    static func preferredMicrophone() -> InputDevice? {
        let all = inputDevices()
        return all.first(where: { $0.isBuiltIn }) ?? all.first(where: { $0.id == defaultDevice(input: true) }) ?? all.first
    }
}
