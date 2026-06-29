import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 전사 결과를 현재 포커스된 입력란에 주입 + 클립보드 복사.
enum TextInjector {
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Cmd+V 합성 (Accessibility 권한 필요). 클립보드에 이미 text가 있어야 함.
    static func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 결과는 **항상 클립보드에 복사**한다 (붙여넣기를 놓쳐도 Cmd+V로 수동 가능).
    /// autoPaste면 추가로 Cmd+V를 합성한 뒤, 기존 클립보드를 복원한다.
    /// 반환: 자동 붙여넣기를 실제로 시도했는지 (false면 권한 없음 → 클립보드만).
    @discardableResult
    static func injectText(_ text: String, autoPaste: Bool) -> Bool {
        let pb = NSPasteboard.general

        if autoPaste && hasAccessibility() {
            // Save existing clipboard so we can restore it after paste
            let snapshot = ClipboardSnapshot(pasteboard: pb)
            copyToClipboard(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                paste()
                // Restore previous clipboard once the target app has consumed Cmd+V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    snapshot.restore(to: pb)
                }
            }
            return true
        }

        // No auto-paste: just leave the text in clipboard for manual Cmd+V
        copyToClipboard(text)
        return false
    }

    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt 의 값 — Swift 6 concurrency 안전을 위해 리터럴 사용
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}

// MARK: - Clipboard snapshot

/// Captures all NSPasteboard items before we overwrite and can restore them later.
private struct ClipboardSnapshot {
    private let items: [(NSPasteboard.PasteboardType, Data)]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.types ?? []).compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for (type, data) in items {
            pasteboard.setData(data, forType: type)
        }
    }
}
