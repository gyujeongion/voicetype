import Foundation

/// Soniox 실시간 WebSocket API 프로토콜 (순수 인코딩/디코딩, 시스템 의존 없음)
/// 엔드포인트: wss://stt-rt.soniox.com/transcribe-websocket
public enum Soniox {
    public static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    public static let realtimeModel = "stt-rt-v5"
    /// finalize 응답 끝에 오는 특수 종료 토큰. 출력에서 제외하고 스트림 종료 신호로 쓴다.
    public static let endToken = "<fin>"
    /// endpoint detection이 말 끊김마다 보내는 구간 경계 토큰. 출력에서 제외하되 스트림은 계속.
    public static let segmentEndToken = "<end>"

    /// 녹음 종료 시 보내는 강제 finalize 메시지 (JSON 텍스트 프레임)
    public static func finalizeMessage() -> String { #"{"type":"finalize"}"# }

    /// 첫 프레임으로 전송하는 설정 메시지
    public struct StartConfig: Codable {
        public var apiKey: String
        public var model: String
        public var audioFormat: String
        public var numChannels: Int
        public var sampleRate: Int
        public var languageHints: [String]
        public var enableEndpointDetection: Bool
        public var context: Context?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
            case audioFormat = "audio_format"
            case numChannels = "num_channels"
            case sampleRate = "sample_rate"
            case languageHints = "language_hints"
            case enableEndpointDetection = "enable_endpoint_detection"
            case context
        }

        public init(apiKey: String,
                    model: String = Soniox.realtimeModel,
                    audioFormat: String = "s16le",
                    numChannels: Int = 1,
                    sampleRate: Int = 16000,
                    languageHints: [String] = ["ko", "en"],
                    enableEndpointDetection: Bool = true,
                    context: Context? = nil) {
            self.apiKey = apiKey
            self.model = model
            self.audioFormat = audioFormat
            self.numChannels = numChannels
            self.sampleRate = sampleRate
            self.languageHints = languageHints
            self.enableEndpointDetection = enableEndpointDetection
            self.context = context
        }

        /// 단어사전 용어를 STT 입력 힌트로 주입 (인식 정확도 향상)
        public struct Context: Codable {
            public var terms: [String]?
            public var text: String?
            public init(terms: [String]? = nil, text: String? = nil) {
                self.terms = terms
                self.text = text
            }
        }

        public func jsonData() throws -> Data {
            let enc = JSONEncoder()
            return try enc.encode(self)
        }
    }

    /// 서버 응답 (토큰 스트림)
    public struct Response: Codable {
        public var tokens: [Token]?
        public var finished: Bool?
        public var errorCode: Int?
        public var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    public struct Token: Codable {
        public var text: String
        public var isFinal: Bool?
        public var confidence: Double?
        public var language: String?

        enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
            case confidence
            case language
        }
    }

    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }
}
