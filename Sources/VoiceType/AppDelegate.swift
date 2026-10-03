import AppKit
import SwiftUI
import VoiceTypeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dictation = DictationController()
    private let recorder = RecorderController()
    /// 녹음 핫키 예약 id. 프로파일은 배열 인덱스(0..n)를 id로 쓰므로 충돌하지 않는다.
    static let recordingHotkeyID: UInt32 = 9000
    /// 받아쓰기 녹음 중에만 잠깐 잡는 Esc(취소) 핫키 id. 녹음이 아닐 땐 Esc를 가로채지 않는다.
    static let cancelHotkeyID: UInt32 = 9001
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
            if n > 0 { self.notify(String(format: self.l.text("recorder.recovered"), n), kind: .info) }
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
            // 녹음·처리 중에만 Esc를 취소 키로 잡는다 (끝나면 즉시 반납 — 평소 Esc는 건드리지 않음)
            if state == .recording || state == .finishing {
                self.hotkey.registerTemporary(id: Self.cancelHotkeyID, keyCode: 53, modifiers: 0)
            } else {
                self.hotkey.unregisterTemporary(id: Self.cancelHotkeyID)
            }
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
        dictation.onNotice = { [weak self] msg in
            self?.notify(msg)
        }
        dictation.onActionNeeded = { [weak self] issue in
            self?.indicator.hide()
            self?.notifyActionable(issue)
        }
        dictation.onInterim = { [weak self] text in
            self?.statusItem.button?.toolTip = text.isEmpty ? "VoiceType" : text
        }
        dictation.onLevel = { [weak self] level in
            self?.indicator.setLevel(level)
        }
    }

    /// 설정의 녹음 폴더를 RecordingStore에 반영. 시작 시 + 설정에서 바꿀 때마다 (재시작 불필요).
    /// 진행 중인 녹음은 자기 회차 폴더 경로를 이미 들고 있어 영향받지 않는다.
    private func applyRecordingFolder() {
        let path = SettingsStore.shared.settings.recordingFolderPath
        let url = path.isEmpty ? RecordingStore.defaultRoot : URL(fileURLWithPath: path, isDirectory: true)
        if RecordingStore.shared.rootURL != url { RecordingStore.shared.rootURL = url }
    }

    private func setupRecorder() {
        applyRecordingFolder()
        settingsVM.onRecordingFolderChange = { [weak self] in self?.applyRecordingFolder() }
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
        recorder.onNotice = { [weak self] msg in self?.notify(msg, kind: .info) }
        recorder.onActionNeeded = { [weak self] issue in self?.notifyActionable(issue) }
        recorder.onMicLevel = { [weak self] level in self?.indicator.setLevel(level) }
        recorder.onSystemLevel = { [weak self] level in
            self?.indicator.setShowsSecondaryLevel(true)
            self?.indicator.setSecondaryLevel(level)
        }
        recorder.onFinished = { [weak self] _ in
            // Finder 자동 팝업 폐기(2026-08-17) — 설정 > 히스토리 탭에서 목록으로 확인,
            // 필요할 때만 버튼으로 Finder 연결. RecordingStore가 이미 갱신을 발행한다.
            self?.notify(self?.l.text("recorder.finished.notify") ?? "녹음이 저장됐습니다.", kind: .info)
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
            if id == Self.cancelHotkeyID {
                guard self.dictation.state == .recording || self.dictation.state == .finishing else { return }
                self.dictation.cancel()
                self.notify(self.l.text("dictation.cancelled"), kind: .info)
                return
            }
            if id == Self.recordingHotkeyID {
                // 받아쓰기가 마이크를 점유/처리 중일 때 F5 녹음을 새로 시작하면 자원이 충돌한다.
                // (반대 방향 — 녹음 중 받아쓰기 차단 — 은 바로 아래에서 처리)
                if !self.recorder.isRecording && self.dictation.isActive {
                    self.notify(self.l.text("recorder.blocked_by_dictation"))
                    return
                }
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
            if id == Self.recordingHotkeyID || id == Self.cancelHotkeyID { return }   // 토글/취소는 release를 쓰지 않는다
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
        let failed = hotkey.registerAll(keys)
        // 매 설정 변경마다 불리므로 값이 바뀔 때만 발행 (불필요한 SwiftUI 재그리기 방지)
        if settingsVM.failedHotkeyIDs != failed { settingsVM.failedHotkeyIDs = failed }
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

    /// 메뉴에서 받아쓰기 시작/종료. 시작은 선택한 프로파일로, 종료는 프로파일·트리거 방식과 무관하게
    /// (꾹누르기 프로파일은 키를 떼야 끝나서 예전엔 메뉴로 못 끝냈다).
    @objc private func dictationMenuAction(_ sender: NSMenuItem) {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        guard !recorder.isRecording else {
            notify(l.text("recorder.dictation_blocked"))
            return
        }
        let profiles = SettingsStore.shared.settings.profiles
        guard sender.tag >= 0, sender.tag < profiles.count else { return }
        var p = profiles[sender.tag]
        p.triggerMode = .toggle   // 메뉴로 시작했으면 메뉴로 끝낸다 (키를 누르고 있는 게 아니므로)
        dictation.trigger(profile: p)
    }

    @objc private func cancelDictationAction() {
        dictation.cancel()
        notify(l.text("dictation.cancelled"), kind: .info)
    }

    @objc private func toggleRecorderAction() {
        if !recorder.isRecording && dictation.isActive {
            notify(l.text("recorder.blocked_by_dictation"))
            return
        }
        recorder.toggle()
    }

    @objc private func copyLastResult() {
        guard let last = HistoryStore.shared.entries.first, !last.finalText.isEmpty else { return }
        TextInjector.copyToClipboard(last.finalText)
        notify(l.text("menu.copied"), kind: .info)
    }

    @objc private func openRecordingFolderAction() {
        let url = RecordingStore.shared.rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
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

    /// 비차단 알림. 경고는 진단 정보의 "마지막 에러"로도 남긴다.
    private func notify(_ message: String, kind: ToastController.Kind = .warning) {
        if kind == .warning { Diagnostics.lastError = message }
        ToastController.shared.show(message, kind: kind)
    }

    /// 사용자가 무언가를 켜야만 풀리는 문제만 버튼 달린 창으로 띄운다.
    private func notifyActionable(_ issue: UserActionNeeded) {
        Diagnostics.lastError = issue.message
        NSApp.activate(ignoringOtherApps: true)   // 메뉴바 앱이라 안 하면 창이 다른 앱 뒤에 뜬다
        let alert = NSAlert()
        alert.messageText = "VoiceType"
        alert.informativeText = issue.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: issue.systemSettingsURL == nil ? l.text("alert.open_settings") : l.text("alert.open_system_settings"))
        alert.addButton(withTitle: l.text("alert.later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = issue.systemSettingsURL {
            NSWorkspace.shared.open(url)
        } else {
            openSettings()
        }
    }

    /// 메뉴는 열 때마다 현재 상태(녹음 중인지, 단축키가 뭔지, 마지막 결과가 있는지)로 다시 만든다.
    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populate(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = SettingsStore.shared.settings
        func shortcut(_ code: UInt32, _ mods: UInt32) -> String {
            code == 0 ? "" : "  \(KeyNames.display(keyCode: code, modifiers: mods))"
        }

        // 받아쓰기 — 프로파일마다 한 줄. 녹음 중엔 종료/취소로 바뀐다.
        if dictation.isRecording {
            menu.addItem(item(l.text("menu.dictation.stop"), #selector(dictationMenuAction(_:)), tag: 0))
            menu.addItem(item(l.text("menu.dictation.cancel"), #selector(cancelDictationAction)))
        } else if dictation.isActive {
            menu.addItem(item(l.text("menu.dictation.cancel"), #selector(cancelDictationAction)))
        } else {
            for (i, p) in settings.profiles.enumerated() {
                let title = String(format: l.text("menu.dictation.start"), p.name) + shortcut(p.hotkeyKeyCode, p.hotkeyModifiers)
                let it = item(title, #selector(dictationMenuAction(_:)), tag: i)
                it.isEnabled = !recorder.isRecording
                menu.addItem(it)
            }
        }

        // F5 회의 녹음
        menu.addItem(.separator())
        let recTitle = (recorder.isRecording ? l.text("menu.recorder.stop") : l.text("menu.recorder.start"))
            + shortcut(settings.recordingHotkeyKeyCode, settings.recordingHotkeyModifiers)
        let rec = item(recTitle, #selector(toggleRecorderAction))
        rec.isEnabled = recorder.state == .idle || recorder.state == .recording
        menu.addItem(rec)
        menu.addItem(item(l.text("menu.recorder.folder"), #selector(openRecordingFolderAction)))

        // 마지막 결과 — 자동 붙여넣기를 놓쳤을 때 메뉴에서 바로 복사
        menu.addItem(.separator())
        let last = item(l.text("menu.copy_last"), #selector(copyLastResult))
        last.isEnabled = !(HistoryStore.shared.entries.first?.finalText.isEmpty ?? true)
        menu.addItem(last)

        menu.addItem(.separator())
        let settingsItem = item(l.text("menu.settings"), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item(l.text("menu.check_updates"), #selector(checkForUpdates)))
        menu.addItem(.separator())
        let quitItem = item(l.text("menu.quit"), #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.tag = tag
        return it
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
