import AppKit
import SwiftUI
import VoiceTypeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let dictation = DictationController()
    private let recorder = RecorderController()
    /// 녹음 핫키 예약 id. 프로파일은 배열 인덱스(0..n)를 id로 쓰므로 충돌하지 않는다.
    static let recordingHotkeyID: UInt32 = 9000
    private var elapsedTimer: Timer?
    private let hotkey = HotkeyManager()
    private let spaceTrigger = SpaceBarTrigger()
    private let indicator = RecordingIndicatorController()
    private var settingsWindow: NSWindow?
    private lazy var settingsVM = SettingsViewModel()
    private var onboarding: OnboardingController?
    private var previewTimer: Timer?

    private var l: LocalizationManager { .shared }

    /// Spotlight·Finder·Dock에서 이미 실행 중인 앱을 다시 열 때 → 설정창 표시
    /// (메뉴바 전용 앱이라 평소엔 창이 없으므로, "앱 실행" = 설정 열기로 동작)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupDictation()
        setupHotkey()
        setupRecorder()
        setupSpaceTrigger()
        Task { @MainActor in
            let n = await self.recorder.recoverIncompleteSessions()
            if n > 0 { self.notify(String(format: self.l.text("recorder.recovered"), n)) }
        }
        SettingsStore.shared.onChange = { [weak self] _ in
            self?.refreshLocalizedUI()
        }
        // 설정에서 인디케이터 디자인을 바꾸면 실제 오버레이로 잠깐 미리보기
        NotificationCenter.default.addObserver(forName: .voiceTypeIndicatorPreview, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?["style"] as? String
            MainActor.assumeIsolated {
                guard let self = self, let raw = raw, let style = IndicatorStyle(rawValue: raw) else { return }
                self.previewIndicator(style)
            }
        }
        _ = UpdaterManager.shared   // Sparkle 자동 업데이트 시작 (스케줄 체크)

        // 첫 실행 → 온보딩 마법사. 이후엔 키 없을 때만 설정창.
        if !OnboardingController.isDone {
            let ob = OnboardingController()
            ob.onFinish = { [weak self] in
                NSApp.setActivationPolicy(.accessory) // 다시 메뉴바 전용으로
                self?.onboarding = nil
            }
            onboarding = ob
            ob.show()
        } else if (SettingsStore.shared.sttAPIKey(for: SettingsStore.shared.settings.stt.provider) ?? "").isEmpty {
            openSettings()
        }
    }

    // MARK: - 메인 메뉴 (Edit 메뉴 — 설정창에서 Cmd+C/V/X/A 작동에 필수)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: l.text("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: l.text("menu.edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: l.text("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: l.text("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: l.text("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: l.text("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: l.text("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: l.text("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 메뉴바

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(.idle)
        rebuildStatusMenu()
    }

    private func updateIcon(_ state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let name: String
        switch state {
        case .idle:      name = "mic"
        case .starting:  name = "mic"
        case .recording: name = "mic.fill"
        case .finishing: name = "ellipsis.circle"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceType")
        button.image?.isTemplate = true
        button.contentTintColor = (state == .recording) ? .systemRed : nil
    }

    // MARK: - 컨트롤러 / 핫키

    private func setupDictation() {
        dictation.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.updateIcon(state)
            switch state {
            case .starting:  break  // transitional — no UI change
            case .recording:
                self.indicator.setStyle(SettingsStore.shared.settings.indicatorStyle)
                self.indicator.setMode(.recording)
                self.indicator.setCaption(self.l.text("indicator.recording"))
                self.indicator.show()
            case .finishing:
                self.indicator.setMode(.processing)
                self.indicator.setCaption(self.l.text("indicator.processing"))
            case .idle:
                self.indicator.hide()
            }
        }
        dictation.onError = { [weak self] msg in
            self?.indicator.hide()
            self?.notify(msg)
        }
        dictation.onInterim = { [weak self] text in
            self?.statusItem.button?.toolTip = text.isEmpty ? "VoiceType" : text
        }
        dictation.onLevel = { [weak self] level in
            self?.indicator.setLevel(level)
        }
    }

    private func setupRecorder() {
        let path = SettingsStore.shared.settings.recordingFolderPath
        if !path.isEmpty {
            RecordingStore.shared.rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        recorder.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.updateRecordingIcon(state)
            switch state {
            case .recording:
                self.indicator.setStyle(SettingsStore.shared.settings.indicatorStyle)
                self.indicator.setMode(.recording)
                self.indicator.setCaption(self.l.text("recorder.indicator.recording"))
                self.indicator.show()
                self.startElapsedTimer()
            case .stopping, .finalizing:
                self.stopElapsedTimer()
                self.indicator.setMode(.processing)
                self.indicator.setCaption(self.l.text("recorder.indicator.finalizing"))
            case .idle:
                self.stopElapsedTimer()
                self.indicator.hide()
            case .starting:
                break
            }
        }
        recorder.onError = { [weak self] msg in self?.notify(msg) }
        recorder.onMicLevel = { [weak self] level in self?.indicator.setLevel(level) }
        recorder.onSystemLevel = { [weak self] level in
            self?.indicator.setShowsSecondaryLevel(true)
            self?.indicator.setSecondaryLevel(level)
        }
        recorder.onFinished = { folder in
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func updateRecordingIcon(_ state: RecorderController.State) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            updateIcon(.idle)
        case .starting, .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill",
                                   accessibilityDescription: "VoiceType 녹음 중")
            button.image?.isTemplate = true
            button.contentTintColor = .systemRed
        case .stopping, .finalizing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "VoiceType 처리 중")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        indicator.setElapsed(0)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.indicator.setElapsed(self.recorder.elapsedSeconds)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        indicator.setElapsed(0)
        indicator.setShowsSecondaryLevel(false)
    }

    /// 설정에서 디자인을 고르면 실제 인디케이터를 약 2.6초간 띄워 가짜 레벨로 미리 보여준다.
    private func previewIndicator(_ style: IndicatorStyle) {
        previewTimer?.invalidate()
        guard style != .off else { indicator.hide(); return }
        indicator.setStyle(style)
        indicator.setMode(.recording)
        indicator.setCaption(l.text("indicator.recording"))
        indicator.show()
        let start = Date()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let t = Date().timeIntervalSince(start)
                if t > 2.6 {
                    self.previewTimer?.invalidate()
                    self.previewTimer = nil
                    self.indicator.hide()
                    return
                }
                let base = abs(sin(t * 3.1)) * 0.10
                let flutter = abs(sin(t * 11.0)) * 0.05
                self.indicator.setLevel(Float(base + flutter))
            }
        }
    }

    private func setupHotkey() {
        hotkey.onTrigger = { [weak self] id in
            guard let self = self else { return }
            if id == Self.recordingHotkeyID {
                self.recorder.toggle()
                return
            }
            // 녹음이 마이크를 점유하는 동안에는 받아쓰기를 막는다
            if self.recorder.isRecording {
                self.notify(self.l.text("recorder.dictation_blocked"))
                return
            }
            let profiles = SettingsStore.shared.settings.profiles
            let idx = Int(id)
            guard idx >= 0, idx < profiles.count else { return }
            self.dictation.trigger(profile: profiles[idx])
        }
        hotkey.onRelease = { [weak self] id in
            guard let self = self else { return }
            if id == Self.recordingHotkeyID { return }   // 녹음은 토글이라 release를 쓰지 않는다
            let profiles = SettingsStore.shared.settings.profiles
            let idx = Int(id)
            guard idx >= 0, idx < profiles.count else { return }
            self.dictation.release(profile: profiles[idx])
        }
        registerProfileHotkeys()
        settingsVM.onProfilesChange = { [weak self] in
            self?.registerProfileHotkeys()
            self?.applySpaceTriggerSettings()
        }
    }

    private func setupSpaceTrigger() {
        spaceTrigger.onActivate = { [weak self] in
            guard let self, !self.recorder.isRecording,
                  let profile = self.spaceBarProfile() else { return }
            var p = profile
            p.triggerMode = .pushToTalk
            self.dictation.trigger(profile: p)
        }
        spaceTrigger.onDeactivate = { [weak self] in
            guard let self,
                  let profile = self.spaceBarProfile() else { return }
            var p = profile
            p.triggerMode = .pushToTalk
            self.dictation.release(profile: p)
        }
        applySpaceTriggerSettings()
    }

    private func applySpaceTriggerSettings() {
        let s = SettingsStore.shared.settings
        spaceTrigger.threshold = s.spaceBarThreshold
        spaceTrigger.excludedBundleIDs = Set(s.spaceBarExcludedAppBundleIDs)
        if s.spaceBarTrigger {
            spaceTrigger.enable()
        } else {
            spaceTrigger.disable()
        }
    }

    private func registerProfileHotkeys() {
        let s = SettingsStore.shared.settings
        var keys = s.profiles.enumerated().map {
            (id: UInt32($0.offset), keyCode: $0.element.hotkeyKeyCode, modifiers: $0.element.hotkeyModifiers)
        }
        keys.append((id: Self.recordingHotkeyID,
                     keyCode: s.recordingHotkeyKeyCode,
                     modifiers: s.recordingHotkeyModifiers))
        hotkey.registerAll(keys)
    }

    private func spaceBarProfile() -> PromptProfile? {
        let settings = SettingsStore.shared.settings
        if let id = settings.spaceBarProfileID,
           let profile = settings.profiles.first(where: { $0.id == id }) {
            return profile
        }
        return settings.profiles.first
    }

    // MARK: - 액션

    @objc private func toggleRecording() {
        // 메뉴에서 토글 → 첫 프로파일 사용 (녹음 중이면 프로파일 무관하게 종료)
        guard let first = SettingsStore.shared.settings.profiles.first else { return }
        dictation.trigger(profile: first)
    }

    @objc private func openSettings() {
        buildSettingsWindowIfNeeded()
        settingsVM.refreshDevices()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildSettingsWindowIfNeeded() {
        guard settingsWindow == nil else { return }
        let lm = LocalizationManager.shared
        let root = LocaleObservingSettings(vm: settingsVM, lm: lm)
        let host = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: host)
        win.title = l.text("window.settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        settingsWindow = win
    }

    @objc private func checkForUpdates() { UpdaterManager.shared.checkForUpdates() }

    @objc private func quit() { NSApp.terminate(nil) }

    private func notify(_ message: String) {
        Diagnostics.lastError = message
        let alert = NSAlert()
        alert.messageText = "VoiceType"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: l.text("alert.ok"))
        alert.addButton(withTitle: l.text("alert.copy_diagnostics"))
        if alert.runModal() == .alertSecondButtonReturn {
            Diagnostics.copyToClipboard()
        }
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: l.text("menu.toggle_recording"), action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: l.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ","))
        let updateItem = NSMenuItem(title: l.text("menu.check_updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: l.text("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func refreshLocalizedUI() {
        setupMainMenu()
        rebuildStatusMenu()
        settingsWindow?.title = l.text("window.settings")
    }
}

extension Notification.Name {
    /// 설정에서 인디케이터 디자인을 바꿀 때 실제 오버레이 미리보기를 요청
    static let voiceTypeIndicatorPreview = Notification.Name("voicetype.indicatorPreview")
}
