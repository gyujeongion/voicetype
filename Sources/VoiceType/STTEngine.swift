import Foundation
import VoiceTypeCore

/// 실시간 STT 엔진 공통 인터페이스.
/// 흐름: start → sendAudio(여러 번) → finish → onFinished
protocol STTEngine: AnyObject {
    var onUpdate: ((String, String) -> Void)? { get set }   // (finalText, interimText)
    var onFinished: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    /// 16kHz mono s16le PCM 스트림 기준.
    func start(apiKey: String, languageHints: [String], terms: [String], customEndpoint: String?)
    func sendAudio(_ data: Data)
    func finish()
    func cancel()
}

enum STTEngineFactory {
    @MainActor
    static func make(_ config: STTConfig) -> STTEngine {
        switch config.provider {
        case .soniox, .custom:
            return SonioxClient()
        case .deepgram:
            return DeepgramClient()
        }
    }

    /// provider별 Keychain 계정 키
    static func keychainAccount(for provider: STTProvider) -> String {
        switch provider {
        case .soniox: return "soniox_api_key"
        case .deepgram: return "deepgram_api_key"
        case .custom: return "custom_stt_api_key"
        }
    }
}
