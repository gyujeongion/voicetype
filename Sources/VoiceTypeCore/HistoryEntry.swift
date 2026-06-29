import Foundation

/// 받아쓰기 1회 기록 — 원문(STT)과 최종본(LLM 후처리 후) 둘 다 보존.
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let profileName: String
    /// STT 전사 원문 (LLM 후처리 전)
    public let rawTranscript: String
    /// 실제로 붙여넣으려 한 최종 텍스트 (LLM 후처리 후)
    public let finalText: String
    /// 자동 붙여넣기를 시도했는지 (false면 클립보드에서 수동 Cmd+V 필요)
    public let autoPasted: Bool

    public init(id: UUID = UUID(),
                timestamp: Date,
                profileName: String,
                rawTranscript: String,
                finalText: String,
                autoPasted: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.profileName = profileName
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.autoPasted = autoPasted
    }

    /// LLM 후처리로 원문이 실제 바뀌었는지
    public var wasProcessed: Bool {
        rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            != finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
