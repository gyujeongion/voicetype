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
        migrateLegacyLLMKeyIfNeeded()
    }

    /// 프로바이더 분리 이전 단일 LLM 키를 현재 endpoint의 프로바이더 슬롯으로 1회 이관.
    /// 비파괴: 원본은 지우지 않고 백업 슬롯으로 옮긴다 → 잘못 귀속돼도 복구 가능하고,
    /// legacy 계정을 비워 다음 실행 때 다른 프로바이더 슬롯으로 재복사(오염)되는 것도 막는다.
    static let legacyBackupAccount = "llm_api_key.legacy_backup"
    private func migrateLegacyLLMKeyIfNeeded() {
        guard let legacy = Keychain.get(LLMPresets.legacyKeychainAccount), !legacy.isEmpty else { return }
        let account = LLMPresets.keychainAccount(endpoint: settings.llm.endpoint)
        // 현재 프로바이더 슬롯이 비어있을 때만 이관(기존 키 덮어쓰기 방지).
        // legacy 키가 실제로 마지막 사용 프로바이더 것일 확률이 높다는 가정 — 틀려도 백업으로 되돌릴 수 있다.
        if Keychain.get(account)?.isEmpty ?? true {
            Keychain.set(legacy, for: account)
        }
        Keychain.set(legacy, for: Self.legacyBackupAccount)   // 복구용 원본 보존
        Keychain.delete(LLMPresets.legacyKeychainAccount)     // 재복사 방지
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

    /// LLM 프로바이더(endpoint)별 API 키. 프로바이더를 바꿔도 각자 키가 보존된다.
    func llmAPIKey(for endpoint: String) -> String? {
        Keychain.get(LLMPresets.keychainAccount(endpoint: endpoint))
    }
    func setLLMAPIKey(_ value: String?, for endpoint: String) {
        let account = LLMPresets.keychainAccount(endpoint: endpoint)
        if let v = value, !v.isEmpty { Keychain.set(v, for: account) }
        else { Keychain.delete(account) }
    }
}
