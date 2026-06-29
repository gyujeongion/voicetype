import Foundation
import VoiceTypeCore

/// OpenAI 호환 chat/completions 엔드포인트로 전사문을 후처리(번역·요약·정리 등).
/// 실패하면 원문을 그대로 반환 (받아쓰기 흐름을 끊지 않음).
enum PostProcessRunner {
    static func run(transcript: String,
                    instruction: String,
                    llm: LLMConfig,
                    apiKey: String?,
                    glossary: [String]) async -> String {
        let needsAPIKey = LLMPresets.requiresAPIKey(endpoint: llm.endpoint)
        guard let url = URL(string: llm.endpoint),
              !transcript.isEmpty else {
            return transcript
        }
        if needsAPIKey && (apiKey?.isEmpty != false) {
            return transcript
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey, !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try PromptBuilder.requestBodyData(transcript: transcript,
                                                             instruction: instruction,
                                                             glossary: glossary,
                                                             config: llm)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return transcript
            }
            return PromptBuilder.extractContent(data) ?? transcript
        } catch {
            return transcript
        }
    }
}
