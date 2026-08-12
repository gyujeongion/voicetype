import Foundation

/// 녹음 회차 폴더 이름 생성. 형식 `YYMMDD_HHMMSS_<4자리 hex>`.
/// 분 단위만으로는 연속 시작 시 충돌할 수 있어 초와 랜덤 접미사를 함께 쓴다. 현지화하지 않는다.
public enum RecordingID {
    /// 회차 ID를 만든다. `random`은 테스트에서 고정값을 주입하려고 파라미터로 받는다.
    public static func make(from date: Date,
                            random: String,
                            timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return "\(f.string(from: date))_\(random)"
    }

    /// 4자리 소문자 16진 접미사.
    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }
}
