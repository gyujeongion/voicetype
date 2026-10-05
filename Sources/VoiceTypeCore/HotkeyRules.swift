import Foundation

/// 전역 단축키 지정 규칙 (순수 로직 — 설정 UI가 저장 전에 검사한다).
public enum HotkeyRules {
    // Carbon 값 (Carbon.HIToolbox를 Core에 끌어오지 않으려고 상수로 둔다)
    static let cmdKey: UInt32 = 256, shiftKey: UInt32 = 512, optionKey: UInt32 = 2048, controlKey: UInt32 = 4096
    static let escapeKeyCode: UInt32 = 53

    /// 수식키 없이 단독으로 써도 타자를 망가뜨리지 않는 키: F1~F20.
    static let standaloneKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1~F12
        105, 107, 113, 106, 64, 79, 80, 90,                       // F13~F20
    ]

    /// 지정할 수 없는 조합이면 사유, 괜찮으면 nil.
    public static func rejectionReason(keyCode: UInt32, modifiers: UInt32) -> String? {
        if keyCode == escapeKeyCode && modifiers == 0 {
            return "Esc는 받아쓰기 취소에 쓰여 단축키로 지정할 수 없습니다."
        }
        // ⇧만 붙은 글자는 대문자 입력이라 단독 키와 같다
        let meaningful = modifiers & (cmdKey | optionKey | controlKey)
        if meaningful == 0 && !standaloneKeyCodes.contains(keyCode) {
            return "이 키를 단독으로 지정하면 평소 타자 입력을 가로챕니다. ⌥·⌃·⌘ 중 하나와 함께 누르거나 F키를 쓰세요."
        }
        return nil
    }

    /// 이미 같은 조합을 쓰는 곳의 이름. 없으면 nil. keyCode 0(미지정)은 충돌하지 않는다.
    /// - Parameters:
    ///   - excludingProfileID: 지금 바꾸는 프로파일 자신 (자기 자신과는 충돌 아님)
    ///   - excludingRecording: 지금 바꾸는 게 F5 녹음 단축키면 true
    public static func conflictOwner(keyCode: UInt32, modifiers: UInt32,
                                     in settings: AppSettings,
                                     excludingProfileID: UUID? = nil,
                                     excludingRecording: Bool = false,
                                     excludingSystemRecording: Bool = false,
                                     recordingName: String = "녹음",
                                     systemRecordingName: String = "시스템 소리 녹음") -> String? {
        guard keyCode != 0 else { return nil }
        for p in settings.profiles where p.id != excludingProfileID {
            if p.hotkeyKeyCode == keyCode && p.hotkeyModifiers == modifiers { return p.name }
        }
        if !excludingRecording,
           settings.recordingHotkeyKeyCode == keyCode,
           settings.recordingHotkeyModifiers == modifiers {
            return recordingName
        }
        if !excludingSystemRecording,
           settings.systemRecordingHotkeyKeyCode == keyCode,
           settings.systemRecordingHotkeyModifiers == modifiers {
            return systemRecordingName
        }
        return nil
    }
}
