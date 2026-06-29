import Foundation

/// LLM 제공자 프리셋 (OpenAI 호환 chat/completions 엔드포인트).
/// 사용자는 프리셋을 고르거나 "커스텀"으로 직접 엔드포인트/모델을 입력한다.
public struct LLMPreset: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let endpoint: String
    public let defaultModel: String
    public let note: String
    public let isCustom: Bool
    public let requiresAPIKey: Bool

    public init(name: String,
                endpoint: String,
                defaultModel: String,
                note: String = "",
                isCustom: Bool = false,
                requiresAPIKey: Bool = true) {
        self.name = name
        self.endpoint = endpoint
        self.defaultModel = defaultModel
        self.note = note
        self.isCustom = isCustom
        self.requiresAPIKey = requiresAPIKey
    }
}

public enum LLMPresets {
    /// 모든 엔드포인트는 OpenAI 호환 /v1/chat/completions.
    /// 모델명은 빠르게 바뀌므로 "권장 기본값"이며 사용자가 수정 가능.
    /// Ranked by response latency for post-processing (faster = less perceived delay after dictation).
    /// Avoid reasoning models (o-series, R1, v4-flash) — they add 4–6s for simple cleanup tasks.
    public static let all: [LLMPreset] = [
        LLMPreset(name: "Groq",
                  endpoint: "https://api.groq.com/openai/v1/chat/completions",
                  defaultModel: "llama-3.1-8b-instant",
                  note: "Fastest (~0.1–0.2s). Free tier available. console.groq.com"),
        LLMPreset(name: "Gemini",
                  endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                  defaultModel: "gemini-2.5-flash-lite",
                  note: "Fast (~0.4s). Strong Korean. aistudio.google.com"),
        LLMPreset(name: "DeepSeek",
                  endpoint: "https://api.deepseek.com/v1/chat/completions",
                  defaultModel: "deepseek-chat",
                  note: "Fast (~0.9s). Use deepseek-chat only — deepseek-reasoner adds 4–6s delay."),
        LLMPreset(name: "Claude",
                  endpoint: "https://api.anthropic.com/v1/chat/completions",
                  defaultModel: "claude-haiku-4-5",
                  note: "High quality. Use Haiku for speed. console.anthropic.com"),
        LLMPreset(name: "OpenAI",
                  endpoint: "https://api.openai.com/v1/chat/completions",
                  defaultModel: "gpt-4o-mini",
                  note: "Reliable. platform.openai.com"),
        LLMPreset(name: "OpenRouter",
                  endpoint: "https://openrouter.ai/api/v1/chat/completions",
                  defaultModel: "google/gemini-2.5-flash-lite",
                  note: "Access any model with one key. openrouter.ai"),
        LLMPreset(name: "Ollama",
                  endpoint: "http://127.0.0.1:11434/v1/chat/completions",
                  defaultModel: "llama3.1",
                  note: "Local model via Ollama. No API key required. Change the model name freely.",
                  requiresAPIKey: false),
        LLMPreset(name: "Custom",
                  endpoint: "",
                  defaultModel: "",
                  note: "Any OpenAI-compatible endpoint.",
                  isCustom: true),
    ]

    /// 현재 endpoint에 매칭되는 프리셋 (없으면 커스텀)
    public static func match(endpoint: String) -> LLMPreset {
        all.first(where: { !$0.isCustom && $0.endpoint == endpoint }) ?? all.first(where: { $0.isCustom })!
    }

    public static func requiresAPIKey(endpoint: String) -> Bool {
        match(endpoint: endpoint).requiresAPIKey
    }

    public static func isLocalEndpoint(_ endpoint: String) -> Bool {
        endpoint.contains("127.0.0.1:11434") || endpoint.contains("localhost:11434")
    }

    public static let suggestedLocalModels: [String] = [
        "llama3.1",
        "llama3.3",
        "llama4:scout",
        "glm4",
        "qwen3",
        "phi4"
    ]
}
