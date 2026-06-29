import Foundation
import CoreAudio

/// 입력(마이크) 장치 열거 + uid ↔ AudioDeviceID 변환.
struct AudioInputDevice: Identifiable, Hashable {
    let id: String      // uid (영속 식별자)
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioDevices {
    /// 현재 연결된 입력 장치 목록
    static func inputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var result: [AudioInputDevice] = []
        for dev in ids {
            guard hasInputChannels(dev) else { continue }
            guard let uid = stringProperty(dev, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(dev, kAudioDevicePropertyDeviceNameCFString) ?? stringProperty(dev, kAudioObjectPropertyName)
            else { continue }
            result.append(AudioInputDevice(id: uid, name: friendlyName(name), deviceID: dev))
        }
        return result
    }

    /// 우선순위 목록에서 현재 연결된 첫 장치만 반환. 없으면 nil.
    /// nil을 받은 쪽에서 AVAudioEngine의 자연 기본값을 그대로 사용해야 한다.
    static func resolvePriority(_ priority: [String]) -> AudioInputDevice? {
        guard !priority.isEmpty else { return nil }
        let available = inputDevices()
        for uid in priority {
            if let match = available.first(where: { $0.id == uid }) {
                return match
            }
        }
        return nil  // 목록에 없으면 강제 지정하지 않음
    }

    /// 명시 선택이 연결되어 있으면 그것을 우선 사용하고, 없으면 우선순위 목록을 본다.
    /// 둘 다 없으면 nil을 반환하여 시스템 기본 입력을 그대로 사용한다.
    static func resolve(selectedUID: String?, priority: [String]) -> AudioInputDevice? {
        let available = inputDevices()
        if let selectedUID,
           let selected = available.first(where: { $0.id == selectedUID }) {
            return selected
        }
        for uid in priority {
            if let match = available.first(where: { $0.id == uid }) {
                return match
            }
        }
        return nil
    }

    /// 현재 연결된 입력 장치 이름 (디버그·표시용).
    static func currentInputDeviceName(priority: [String]) -> String {
        if let dev = resolvePriority(priority) { return dev.name }
        if let def = defaultInputDevice(),
           let dev = inputDevices().first(where: { $0.deviceID == def }) {
            return dev.name
        }
        return inputDevices().first?.name ?? "Unknown"
    }

    /// 하위 호환 — 폴백 포함 기존 동작 유지 (설정화면 장치 목록 등에서 사용)
    static func resolve(priority: [String]) -> AudioInputDevice? {
        let available = inputDevices()
        for uid in priority {
            if let match = available.first(where: { $0.id == uid }) {
                return match
            }
        }
        if let def = defaultInputDevice() {
            return available.first(where: { $0.deviceID == def }) ?? available.first
        }
        return available.first
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else {
            return nil
        }
        return dev
    }

    // MARK: - helpers

    private static func hasInputChannels(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, bufList) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufList.assumingMemoryBound(to: AudioBufferList.self))
        for buf in abl where buf.mNumberChannels > 0 { return true }
        return false
    }

    private static func stringProperty(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw)
            }
        }
        guard status == noErr, let s = cf as String? else { return nil }
        return s
    }

    /// 일부 USB 장치는 사람이 읽을 장치명 대신 CoreAudio UID를 이름으로 돌려준다.
    private static func friendlyName(_ raw: String) -> String {
        guard raw.hasPrefix("AppleUSBAudioEngine:") else { return raw }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return raw }
        let manufacturer = parts[1]
        let product = parts[2]
        if manufacturer.isEmpty || manufacturer == "Unknown Manufacturer" {
            return product
        }
        return "\(product) · \(manufacturer)"
    }
}
