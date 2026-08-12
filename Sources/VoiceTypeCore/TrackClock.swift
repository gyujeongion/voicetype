import Foundation

/// 한 트랙의 "기록된 시간"과 "실제 경과 시간"을 대조해, 메워야 할 무음 길이를 산출한다.
///
/// 캡처 콜백은 버퍼를 불규칙하게 전달하며 슬립·드롭아웃 시 아예 끊긴다.
/// 무음을 메우지 않으면 파일 시간축이 벽시계보다 짧아지고, 전사 타임스탬프가
/// 뒤로 갈수록 어긋난다. 파일 시간축을 항상 벽시계에 맞춰 두면
/// 전사 결과의 타임스탬프를 보정 없이 그대로 쓸 수 있다.
public struct TrackClock: Sendable {
    /// 목표 샘플레이트(Hz)
    public let sampleRate: Double
    /// 이 값을 넘는 공백만 불연속으로 처리한다(초). 미세한 지터까지 메우면 오히려 흔들린다.
    public let gapThreshold: Double

    /// 지금까지 파일에 기록된 길이(초)
    public private(set) var writtenSeconds: Double = 0

    public init(sampleRate: Double, gapThreshold: Double = 0.1) {
        self.sampleRate = sampleRate
        self.gapThreshold = gapThreshold
    }

    /// 실제 데이터를 기록한 뒤 호출한다.
    public mutating func advance(frameCount: Int) {
        writtenSeconds += Double(frameCount) / sampleRate
    }

    /// 버퍼를 쓰기 직전에 호출한다.
    /// 반환값이 있으면 그만큼 무음을 먼저 써야 하며, 그 길이는 이미 기록량에 반영된다.
    public mutating func silenceNeeded(atWallTime wallTime: Double) -> Double? {
        let gap = wallTime - writtenSeconds
        guard gap > gapThreshold else { return nil }
        writtenSeconds += gap
        return gap
    }

    /// 불연속 기록을 만든다.
    ///
    /// - Important: 반드시 `silenceNeeded`가 `writtenSeconds`를 늘린 **뒤에** 호출해야 한다.
    ///   `gapSeconds`를 되빼서 무음 삽입 전 지점을 복원하기 때문이다.
    public mutating func recordGap(wallTime: Double,
                                   gapSeconds: Double,
                                   reason: String) -> DiscontinuityRecord {
        DiscontinuityRecord(fileTime: writtenSeconds - gapSeconds,
                            wallTime: wallTime,
                            gapSeconds: gapSeconds,
                            reason: reason)
    }
}
