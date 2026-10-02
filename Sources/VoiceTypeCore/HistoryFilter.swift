import Foundation

/// 히스토리 검색 (순수 로직). 공백으로 나눈 단어가 모두 들어 있는 항목만 남긴다.
/// 최종본·원문(STT)·프로파일 이름을 대소문자 무시로 본다 — 후처리로 문장이 바뀌어도 말한 단어로 찾을 수 있게.
public enum HistoryFilter {
    public static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [entry.finalText, entry.rawTranscript, entry.profileName].joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { matches($0, query: q) }
    }
}
