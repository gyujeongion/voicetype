import Foundation

/// Soniox 토큰 스트림을 최종 전사문으로 조립한다 (순수 로직).
/// is_final 토큰은 확정 버퍼에 누적하고, 비확정 토큰은 임시(interim)로 둔다.
public final class TranscriptAssembler {
    private(set) public var finalText: String = ""
    private(set) public var interimText: String = ""
    /// `<fin>` 종료 토큰 또는 finished 메시지를 받았는가
    private(set) public var isFinished: Bool = false

    public init() {}

    public func reset() {
        finalText = ""
        interimText = ""
        isFinished = false
    }

    /// 응답 한 건을 반영. 확정 텍스트가 갱신되었으면 true.
    @discardableResult
    public func ingest(_ response: Soniox.Response) -> Bool {
        if response.finished == true { isFinished = true }
        guard let tokens = response.tokens, !tokens.isEmpty else { return false }
        var newFinal = ""
        var newInterim = ""
        for t in tokens {
            // 종료 토큰: 누적하지 않고 종료 신호로만 처리
            if t.text == Soniox.endToken {
                isFinished = true
                continue
            }
            // 구간 경계 토큰(endpoint detection): 출력에서 제외하되 스트림은 계속
            if t.text == Soniox.segmentEndToken {
                continue
            }
            if t.isFinal == true {
                newFinal += t.text
            } else {
                newInterim += t.text
            }
        }
        if !newFinal.isEmpty {
            finalText += newFinal
        }
        interimText = newInterim
        return !newFinal.isEmpty
    }

    /// 현재까지 보이는 전체 텍스트 (확정 + 임시)
    public var displayText: String {
        finalText + interimText
    }

    /// 최종 결과 — 양끝 공백 정리
    public func result() -> String {
        finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
