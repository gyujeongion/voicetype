import Foundation
import VoiceTypeCore

/// 후처리 결과. 실패해도 받아쓰기 흐름은 끊지 않고 원문(text)을 쓰되,
/// 실패 사유를 함께 돌려줘 사용자가 "번역이 안 됐다"는 걸 알 수 있게 한다.
struct PostProcessOutcome: Sendable {
    let text: String
    /// nil이면 성공. 값이 있으면 원문으로 대체됐다는 뜻.
    let failure: String?
}

/// OpenAI 호환 chat/completions 엔드포인트로 전사문을 후처리(번역·요약·정리 등).
/// 실패하면 원문을 그대로 반환 (받아쓰기 흐름을 끊지 않음).
enum PostProcessRunner {
    static func run(transcript: String,
                    instruction: String,
                    llm: LLMConfig,
                    apiKey: String?,
                    glossary: [String]) async -> PostProcessOutcome {
        guard !transcript.isEmpty else { return PostProcessOutcome(text: transcript, failure: nil) }
        guard let url = URL(string: llm.endpoint), url.scheme != nil else {
            return PostProcessOutcome(text: transcript, failure: "LLM 엔드포인트 주소가 올바르지 않습니다.")
        }
        if LLMPresets.requiresAPIKey(endpoint: llm.endpoint) && (apiKey?.isEmpty != false) {
            return PostProcessOutcome(text: transcript, failure: "LLM API 키가 설정되지 않았습니다. 설정 > 일반에서 입력하세요.")
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
                return PostProcessOutcome(text: transcript,
                                          failure: httpFailureMessage(status: http.statusCode, data: data, model: llm.model))
            }
            // content가 nil이거나(파싱 실패) 빈 문자열이면(모델이 거부/공백 응답) 원문을 지킨다 —
            // 여기서 STT 원문을 잃으면 사용자는 받아쓴 내용 자체를 통째로 잃는다.
            guard let result = PromptBuilder.extractContent(data), !result.isEmpty else {
                return PostProcessOutcome(text: transcript, failure: "LLM이 빈 응답을 돌려줬습니다.")
            }
            return PostProcessOutcome(text: result, failure: nil)
        } catch {
            return PostProcessOutcome(text: transcript, failure: KeyTester.networkMessage(error))
        }
    }

    /// HTTP 오류 상태 → 사용자용 문장. 키 테스트와 실제 후처리가 같은 문장을 쓴다.
    static func httpFailureMessage(status: Int, data: Data, model: String) -> String {
        switch status {
        case 401, 403: return "LLM 키가 유효하지 않습니다. 키를 확인하세요."
        case 402: return "LLM 계정 잔액이 부족합니다."
        case 404: return "모델명 '\(model)'을 찾을 수 없습니다. 모델명을 확인하세요."
        case 429: return "LLM 요청 한도(rate limit)를 초과했습니다. 잠시 후 다시 시도하세요."
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            return "LLM 오류 (\(status))\(msg.map { ": \($0)" } ?? "")"
        }
    }
}
