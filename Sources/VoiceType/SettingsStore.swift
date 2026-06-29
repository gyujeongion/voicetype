import Foundation
import VoiceTypeCore

/// AppSettings 영속화 + 비밀키(Keychain) 통합. 메인 스레드에서 접근.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    /// 설정 파일 — 앱 번들 밖. 재빌드·재설치·앱 삭제와 무관하게 보존된다.
    /// ~/Library/Application Support/VoiceType/settings.json
    private let fileURL: URL
    private(set) var settings: AppSettings

    var onChange: ((AppSettings) -> Void)?

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let s = AppSettings.decoded(from: data) {
            self.settings = s
        } else {
            // 구버전 UserDefaults에서 1회 마이그레이션
            if let data = UserDefaults.standard.data(forKey: "voicetype.settings.v1"),
               let s = AppSettings.decoded(from: data) {
                self.settings = s
            } else {
                self.settings = .default
            }
            persist()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
        persist()
        onChange?(s)
    }

    func persist() {
        if let data = try? settings.encoded() {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // 비밀키
    var sonioxAPIKey: String? {
        get { Keychain.get(Keychain.sonioxKey) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: Keychain.sonioxKey) }
            else { Keychain.delete(Keychain.sonioxKey) }
        }
    }

    /// STT provider별 키 (soniox/deepgram/custom)
    func sttAPIKey(for provider: STTProvider) -> String? {
        Keychain.get(STTEngineFactory.keychainAccount(for: provider))
    }
    func setSTTAPIKey(_ value: String?, for provider: STTProvider) {
        let account = STTEngineFactory.keychainAccount(for: provider)
        if let v = value, !v.isEmpty { Keychain.set(v, for: account) }
        else { Keychain.delete(account) }
    }

    var llmAPIKey: String? {
        get { Keychain.get(Keychain.llmKey) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: Keychain.llmKey) }
            else { Keychain.delete(Keychain.llmKey) }
        }
    }
}
