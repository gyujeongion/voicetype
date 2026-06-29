import Carbon.HIToolbox
import CoreGraphics
import AppKit

/// Space 키를 일정 횟수 이상 연속 입력하면 음성 입력 모드로 전환.
/// Space를 놓으면 녹음 종료. CGEventTap으로 전역 이벤트 인터셉트.
final class SpaceBarTrigger: @unchecked Sendable {

    var threshold: Int = 3          // 이 횟수 이상 key-repeat이면 기동
    var onActivate:  (() -> Void)?  // 녹음 시작 콜백
    var onDeactivate: (() -> Void)? // 녹음 종료 콜백
    var excludedBundleIDs: Set<String> = []

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var repeatCount = 0
    private var isActive = false    // 현재 음성 입력 중

    // MARK: - 활성화 / 비활성화

    func enable() {
        guard tapPort == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: _spaceEventCallback,
            userInfo: ptr
        )
        guard let port = tapPort else {
            NSLog("[SpaceBarTrigger] CGEventTap 생성 실패 — Accessibility 권한 확인")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func disable() {
        guard let port = tapPort else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        tapPort = nil
        repeatCount = 0
        isActive = false
    }

    // MARK: - 이벤트 처리 (콜백에서 호출, 메인 스레드)

    fileprivate func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 49 else { return Unmanaged.passRetained(event) }  // kVK_Space = 49
        if shouldBypassForFrontmostApp() {
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .keyDown:
            if isActive { return nil }  // 녹음 중 — Space 이벤트 전부 먹기

            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                repeatCount += 1
                if repeatCount >= threshold {
                    isActive = true
                    let spacesToErase = repeatCount + 1  // 최초 1회 + repeat N회
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.sendBackspaces(spacesToErase)
                        self.onActivate?()
                    }
                    return nil
                }
            }
            // 아직 임계값 미달 또는 최초 누름 → 그냥 통과
            return Unmanaged.passRetained(event)

        case .keyUp:
            defer { repeatCount = 0 }
            if isActive {
                isActive = false
                DispatchQueue.main.async { [weak self] in self?.onDeactivate?() }
                return nil  // keyUp도 먹기
            }
            return Unmanaged.passRetained(event)

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - 누적된 Space 지우기

    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true)?
                .post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false)?
                .post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func shouldBypassForFrontmostApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return excludedBundleIDs.contains(bundleID)
    }
}

// @convention(c) — 캡처 불가, userInfo로 self 전달
private let _spaceEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    return Unmanaged<SpaceBarTrigger>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .processEvent(type: type, event: event)
}
