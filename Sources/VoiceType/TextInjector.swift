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
    ///
    /// `expectedAppBundleID`가 주어지면, 실제로 키 입력을 보내기 직전에 맨 앞 앱이
    /// 그 앱과 같은지 다시 확인한다 — 처리(LLM 후처리 등)가 걸리는 동안 사용자가 다른
    /// 앱으로 옮겨갔다면 그 앱에 엉뚱하게 붙여넣기하지 않고 건너뛴다(텍스트는 클립보드에 남김).
    ///
    /// 반환: 자동 붙여넣기를 실제로 "시도"했는지 (false면 권한 없음 → 클립보드만).
    /// 앱 전환으로 건너뛴 경우는 `onSkippedDueToAppSwitch`로 비동기 통지한다.
    @discardableResult
    static func injectText(_ text: String, autoPaste: Bool,
                           expectedAppBundleID: String? = nil,
                           onSkippedDueToAppSwitch: (@Sendable () -> Void)? = nil) -> Bool {
        let pb = NSPasteboard.general

        if autoPaste && hasAccessibility() {
            // Save existing clipboard so we can restore it after paste
            let snapshot = ClipboardSnapshot(pasteboard: pb)
            copyToClipboard(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if let expectedAppBundleID,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedAppBundleID {
                    // 다른 앱으로 전환됨 — 붙여넣기 건너뜀. 클립보드의 결과 텍스트는 그대로 둔다
                    // (기존 클립보드로 복원하면 방금 만든 결과를 사용자가 잃어버린다).
                    onSkippedDueToAppSwitch?()
                    return
                }
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
