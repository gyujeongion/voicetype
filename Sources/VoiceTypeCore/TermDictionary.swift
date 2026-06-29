import Foundation

/// Custom vocabulary — list terms separated by newlines or commas.
/// All terms are injected into the STT engine's context hint field so the model
/// corrects phonetically similar speech to the exact registered spelling.
/// e.g. "Aphex Twin, Four Tet, Floating Points" → STT learns the exact capitalisation.
public struct TermDictionary: Codable, Sendable {
    /// 메모장 형태 자유 입력 (한 줄에 하나 또는 쉼표 구분)
    public var rawText: String

    public init(rawText: String = "") {
        self.rawText = rawText
    }

    /// Returns terms for STT context hints and LLM glossary.
    /// Splits on newline/comma/semicolon. Parenthetical aliases are extracted as separate terms.
    /// e.g. "Four Tet (포 텟)" → ["Four Tet", "포 텟"]. Multi-word terms like "Floating Points" preserved.
    public func hintTerms() -> [String] {
        var result: [String] = []
        let items = rawText.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "、" || $0 == ";" })
        for item in items {
            var line = String(item)
            // 괄호 안 표기 추출 (여러 개 가능)
            while let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") {
                let inside = line[line.index(after: open)..<close]
                    .trimmingCharacters(in: .whitespaces)
                if !inside.isEmpty { result.append(inside) }
                line.removeSubrange(open...close)
            }
            let outside = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !outside.isEmpty { result.append(outside) }
        }
        // 중복 제거(순서 유지)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
