import Foundation

/// 사용자가 직접 무언가를 켜거나 입력해야만 풀리는 문제. 토스트로 흘려보내면 안 되고,
/// 해결 버튼(시스템 설정 열기·VoiceType 설정 열기)이 달린 창으로 보여준다.
enum UserActionNeeded {
    case microphoneDenied
    case screenRecordingDenied
    case sttKeyMissing(providerName: String)

    var message: String {
        switch self {
        case .microphoneDenied:
            return "마이크 권한이 꺼져 있어 녹음할 수 없습니다.\n시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 VoiceType을 켜세요."
        case .screenRecordingDenied:
            return "컴퓨터 소리를 녹음하려면 화면 기록 권한이 필요합니다(오디오만 사용하고 화면은 녹화하지 않습니다).\n시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 VoiceType을 켠 뒤 앱을 다시 실행하세요."
        case .sttKeyMissing(let name):
            return "\(name) API 키가 설정되지 않았습니다. 설정 > 일반에서 키를 입력하세요."
        }
    }

    /// nil이면 VoiceType 설정창을 연다.
    var systemSettingsURL: URL? {
        switch self {
        case .microphoneDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecordingDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .sttKeyMissing:
            return nil
        }
    }
}
