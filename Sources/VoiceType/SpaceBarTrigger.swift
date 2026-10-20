import Carbon.HIToolbox
import CoreGraphics
import AppKit
import VoiceTypeCore

/// Space 키를 일정 횟수 이상 연속 입력하면 음성 입력 모드로 전환.
/// Space를 놓으면 녹음 종료. CGEventTap으로 전역 이벤트 인터셉트.
///
/// 이 탭은 시스템의 **모든 키 입력**이 거쳐 가는 길목이다. 그래서:
/// - 메인 스레드가 아니라 전용 스레드의 런루프에서 돈다. 메인이 오디오 엔진 기동(에어팟은 1~2초)·
///   설정 화면 갱신 등으로 막혀도 다른 앱의 타이핑이 지연되지 않는다. 지연되면 키가 몰려 들어가
///   한글 조합이 깨지고, 시스템이 탭을 타임아웃으로 꺼버린다.
/// - 통과시키는 이벤트는 passUnretained로 돌려준다. passRetained는 키 입력마다 CGEvent를 누수한다.
/// - 시스템이 탭을 끄면(타임아웃·사용자 입력) 즉시 다시 켠다.
final class SpaceBarTrigger: @unchecked Sendable {

    var onActivate:  (() -> Void)?  // 녹음 시작 콜백 (메인 스레드)
    var onDeactivate: (() -> Void)? // 녹음 종료 콜백 (메인 스레드)

    // 설정값·맨 앞 앱은 메인에서 쓰고 탭 스레드에서 읽으므로 락으로 보호한다
    private let lock = NSLock()
    private var _threshold = 3
    private var _excludedBundleIDs: Set<String> = []
    private var frontmostBundleID: String?

    var threshold: Int {
        get { lock.withLock { _threshold } }
        set { lock.withLock { _threshold = newValue } }
    }
    var excludedBundleIDs: Set<String> {
        get { lock.withLock { _excludedBundleIDs } }
        set { lock.withLock { _excludedBundleIDs = newValue } }
    }

    // 아래는 탭 스레드에서만 만진다
    private var detector = SpaceHoldDetector(threshold: 3)
    private var tapPort: CFMachPort?

    // 메인 스레드에서만 만진다
    private var tapRunLoop: CFRunLoop?
    private var activationObserver: NSObjectProtocol?

    // MARK: - 활성화 / 비활성화 (메인 스레드)

    func enable() {
        guard tapRunLoop == nil else { return }
        observeFrontmostApp()

        let ready = DispatchSemaphore(value: 0)
        let startedLoop = RunLoopBox()
        let thread = Thread { [self] in
            let mask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue)
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: _spaceEventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                NSLog("[SpaceBarTrigger] CGEventTap 생성 실패 — Accessibility 권한 확인")
                ready.signal()
                return
            }
            tapPort = port
            detector.reset()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            startedLoop.loop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "VoiceType.SpaceBarTrigger"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        tapRunLoop = startedLoop.loop
    }

    func disable() {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
        guard let rl = tapRunLoop else { return }
        tapRunLoop = nil
        // 탭 정리는 탭 스레드에서 한다 (콜백과 동시에 상태를 만지지 않도록)
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            tapPort = nil
            if detector.isActive {
                // Space를 누른 채 기능을 껐다 — 받아쓰기가 키 뗌을 영영 못 받으니 여기서 끝낸다
                DispatchQueue.main.async { [weak self] in self?.onDeactivate?() }
            }
            detector.reset()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
    }

    /// 매 키 입력마다 NSWorkspace를 조회하지 않도록 맨 앞 앱을 알림으로 캐시한다.
    private func observeFrontmostApp() {
        guard activationObserver == nil else { return }
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.withLock { frontmostBundleID = current }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            self?.lock.withLock { self?.frontmostBundleID = id }
        }
    }

    // MARK: - 이벤트 처리 (탭 스레드)

    fileprivate func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .keyDown, .keyUp:
            break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        default:
            return pass
        }

        // 대부분의 키는 여기서 바로 통과 — 이 아래로는 Space만 내려간다
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else { return pass }

        if type == .keyUp {
            switch detector.keyUp() {
            case .deactivate:
                DispatchQueue.main.async { [weak self] in self?.onDeactivate?() }
                return nil  // keyUp도 먹기
            default:
                return pass
            }
        }

        if !detector.isActive {
            // ⌃Space·⌘Space(입력 소스 전환·Spotlight)는 건드리지 않는다
            if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                return pass
            }
            let (excluded, threshold) = lock.withLock {
                (frontmostBundleID.map { _excludedBundleIDs.contains($0) } ?? false, _threshold)
            }
            if excluded { return pass }
            detector.threshold = threshold
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch detector.keyDown(isRepeat: isRepeat) {
        case .pass:
            return pass
        case .swallow:
            return nil
        case .activate(let eraseCount):
            // 콜백이 끝난 직후 같은 스레드에서 지운다 — 사용자의 다음 키보다 먼저 들어가게
            CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) {
                Self.sendBackspaces(eraseCount)
            }
            DispatchQueue.main.async { [weak self] in self?.onActivate?() }
            return nil
        case .deactivate:
            return pass
        }
    }

    // MARK: - 누적된 Space 지우기

    private static func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)?
                .post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)?
                .post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// 탭 스레드가 만든 런루프를 세마포어 대기 후 메인에서 받아 가기 위한 상자
private final class RunLoopBox: @unchecked Sendable {
    var loop: CFRunLoop?
}

// @convention(c) — 캡처 불가, userInfo로 self 전달
private let _spaceEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SpaceBarTrigger>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .processEvent(type: type, event: event)
}
