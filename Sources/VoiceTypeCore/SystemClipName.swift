import Foundation

/// F6(시스템 소리만) 녹음 파일 이름 — 폴더·json 없이 날짜·시간만으로 구분한다.
/// 예: "2026-10-06 04-45-12". (콜론은 파일명에 못 쓰므로 시간은 하이픈)
public enum SystemClipName {
    private static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }

    public static func make(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone).string(from: date)
    }

    /// 확장자·" (2)" 같은 중복 접미사를 떼고 날짜를 읽는다. 형식이 다르면 nil.
    public static func parse(_ fileName: String, timeZone: TimeZone = .current) -> Date? {
        var base = (fileName as NSString).deletingPathExtension
        if let r = base.range(of: #" \(\d+\)$"#, options: .regularExpression) { base.removeSubrange(r) }
        return formatter(timeZone).date(from: base)
    }
}
