import Foundation
import Carbon.HIToolbox
import AppKit

/// 전역 단축키 등록 (Carbon RegisterEventHotKey). 권한 불필요.
/// keyCode/modifiers 는 런타임에 변경 가능. 여러 프로파일 핫키를 동시 등록.
final class HotkeyManager: @unchecked Sendable {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]   // id → ref
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x56545950 // 'VTYP'

    /// 눌린 핫키의 id (= 프로파일 인덱스). 메인 스레드.
    var onTrigger: ((UInt32) -> Void)?
    /// 뗀 핫키의 id — push-to-talk 모드에서 녹음 종료 트리거. 메인 스레드.
    var onRelease: ((UInt32) -> Void)?

    init() {
        installHandler()
    }

    deinit {
        unregisterAll()
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    private func installHandler() {
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        specs.withUnsafeBufferPointer { buf in
            _ = InstallEventHandler(GetEventDispatcherTarget(), { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let id = hkID.id
                if GetEventKind(eventRef) == UInt32(kEventHotKeyPressed) {
                    DispatchQueue.main.async { mgr.onTrigger?(id) }
                } else {
                    DispatchQueue.main.async { mgr.onRelease?(id) }
                }
                return noErr
            }, 2, buf.baseAddress, selfPtr, &eventHandler)
        }
    }

    /// 프로파일 단축키 일괄 (재)등록. keys = [(id, keyCode, modifiers)]
    func registerAll(_ keys: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)]) {
        unregisterAll()
        for k in keys where k.keyCode != 0 {   // keyCode 0 = 미지정 → 등록 안 함
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: k.id)
            let status = RegisterEventHotKey(k.keyCode, k.modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref = ref { hotKeyRefs[k.id] = ref }
        }
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }
}

/// Carbon keyCode ↔ 사람이 읽는 이름 (설정 UI용)
enum KeyNames {
    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyLabel(keyCode)
        return s
    }

    static func keyLabel(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            // Function keys
            UInt32(kVK_F1): "F1",  UInt32(kVK_F2): "F2",  UInt32(kVK_F3): "F3",  UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5",  UInt32(kVK_F6): "F6",  UInt32(kVK_F7): "F7",  UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9",  UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
            // Special keys
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "PgUp", UInt32(kVK_PageDown): "PgDn",
            // ANSI letters
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            // ANSI numbers
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            // ANSI punctuation
            UInt32(kVK_ANSI_Grave): "`",   UInt32(kVK_ANSI_Minus): "-",
            UInt32(kVK_ANSI_Equal): "=",   UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",",   UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}
