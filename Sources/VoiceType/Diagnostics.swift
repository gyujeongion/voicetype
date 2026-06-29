import AppKit
import AVFoundation
import VoiceTypeCore

/// 지원·버그리포트용 진단 정보. API 키는 절대 포함하지 않고 "설정됨/없음"만 표기.
@MainActor
enum Diagnostics {
    /// 가장 최근 사용자에게 보인 에러 (진단에 포함)
    static var lastError: String?

    static func report() -> String {
        let s = SettingsStore.shared.settings
        let appVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "허용"
        case .denied: mic = "거부"
        case .restricted: mic = "제한"
        case .notDetermined: mic = "미결정"
        @unknown default: mic = "?"
        }
        let ax = TextInjector.hasAccessibility() ? "허용" : "없음"

        let provider = s.stt.provider.rawValue
        let sttKey = (SettingsStore.shared.sttAPIKey(for: s.stt.provider)?.isEmpty == false) ? "설정됨" : "없음"
        let llmKey = (SettingsStore.shared.llmAPIKey?.isEmpty == false) ? "설정됨" : "없음"

        return """
        VoiceType 진단 정보
        ─────────────────
        앱 버전: \(appVer) (\(build))
        macOS: \(os)
        마이크 권한: \(mic)
        손쉬운 사용 권한: \(ax)
        자동 붙여넣기: \(s.autoPaste ? "켜짐" : "꺼짐")
        STT 엔진: \(provider) / 키 \(sttKey)
        LLM: \(s.llm.model) @ \(s.llm.endpoint) / 키 \(llmKey)
        언어 힌트: \(s.languageHints.joined(separator: ", "))
        프로파일: \(s.profiles.count)개
        단어사전: \(s.dictionary.hintTerms().count)개 용어
        마지막 에러: \(lastError ?? "없음")
        ─────────────────
        """
    }

    static func copyToClipboard() {
        TextInjector.copyToClipboard(report())
    }
}
