import AppKit
import SwiftUI
import Carbon.HIToolbox

/// NSViewRepresentable 기반 키 캡처 뷰.
/// first responder로 승격되어 keyDown(with:)를 직접 수신 — SwiftUI local monitor 방식보다 확실함.
struct HotkeyCaptureView: NSViewRepresentable {
    var onCapture: (UInt32, UInt32) -> Void   // (keyCode, carbonModifiers)
    var onCancel: () -> Void

    func makeNSView(context: Context) -> _CaptureNSView {
        _CaptureNSView(onCapture: onCapture, onCancel: onCancel)
    }

    func updateNSView(_ nsView: _CaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        // first responder는 viewDidMoveToWindow에서 처리
    }
}

final class _CaptureNSView: NSView {
    var onCapture: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    init(onCapture: @escaping (UInt32, UInt32) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // DispatchQueue.main.async 보다 안정적 — window에 실제로 붙은 직후 호출됨
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt32(kVK_Escape) {
            onCancel()
            return
        }
        // modifier-only 입력(shift·option·cmd·ctrl 단독)은 keyCode가 해당 modifier key → 무시
        let ignoredKeyCodes: Set<UInt32> = [
            UInt32(kVK_Shift), UInt32(kVK_RightShift),
            UInt32(kVK_Option), UInt32(kVK_RightOption),
            UInt32(kVK_Command), UInt32(kVK_RightCommand),
            UInt32(kVK_Control), UInt32(kVK_RightControl),
            UInt32(kVK_CapsLock), UInt32(kVK_Function),
        ]
        let keyCode = UInt32(event.keyCode)
        guard !ignoredKeyCodes.contains(keyCode) else { return }

        let mods = carbonModifiers(event.modifierFlags)
        onCapture(keyCode, mods)
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}
