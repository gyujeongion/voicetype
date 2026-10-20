import Foundation

/// Space를 꾹 누르면(자동 반복 N회) 받아쓰기를 시작하는 판정기. 키 이벤트 탭과 분리해 테스트한다.
///
/// 활성화 직전까지 통과시킨 Space 수 = 최초 1회 + 자동 반복 (repeatCount - 1)회 = repeatCount.
/// 그 수만큼만 지워야 한다 — 하나 더 지우면 Space 앞에 쓴 글자(한글 마지막 음절 등)가 날아간다.
public struct SpaceHoldDetector: Sendable {
    public enum Action: Equatable, Sendable {
        case pass
        case swallow
        case activate(eraseCount: Int)
        case deactivate
    }

    public var threshold: Int
    public private(set) var isActive = false
    private var repeatCount = 0

    public init(threshold: Int) {
        self.threshold = threshold
    }

    public mutating func keyDown(isRepeat: Bool) -> Action {
        if isActive { return .swallow }   // 녹음 중 — Space 전부 먹기
        guard isRepeat else {
            repeatCount = 0
            return .pass
        }
        repeatCount += 1
        guard repeatCount >= max(1, threshold) else { return .pass }
        isActive = true
        return .activate(eraseCount: repeatCount)
    }

    public mutating func keyUp() -> Action {
        repeatCount = 0
        guard isActive else { return .pass }
        isActive = false
        return .deactivate
    }

    public mutating func reset() {
        repeatCount = 0
        isActive = false
    }
}
