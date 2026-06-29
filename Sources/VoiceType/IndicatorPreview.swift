import AppKit
import Foundation

/// 녹음 인디케이터 비주얼 미리보기 (마이크 없이). 가짜 레벨로 막대 출렁임 재현.
@MainActor
enum IndicatorPreview {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let ctrl = RecordingIndicatorController()
        ctrl.setMode(.recording)
        ctrl.setCaption("녹음 중")
        ctrl.show()

        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start)
                // 말하는 듯한 불규칙 레벨
                let base = abs(sin(t * 3.1)) * 0.10
                let flutter = abs(sin(t * 11.0)) * 0.04
                ctrl.setLevel(Float(base + flutter))
            }
        }
        app.run()
    }
}
