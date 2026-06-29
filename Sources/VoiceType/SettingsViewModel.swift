import SwiftUI
import AppKit
import Carbon.HIToolbox
import CoreAudio
import VoiceTypeCore

struct AppExclusionItem: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persist() }
    }
    /// 현재 선택된 STT provider의 API 키
    @Published var sttKey: String {
        didSet { SettingsStore.shared.setSTTAPIKey(sttKey, for: settings.stt.provider) }
    }
    @Published var llmKey: String {
        didSet { SettingsStore.shared.llmAPIKey = llmKey }
    }
    @Published var devices: [AudioInputDevice] = []
    /// 단축키 캡처 중인 프로파일 id (nil이면 캡처 안 함)
    @Published var capturingProfileID: UUID?

    /// 프로파일/단축키 변경 시 핫키 재등록 콜백 (AppDelegate가 연결)
    var onProfilesChange: (() -> Void)?

    init() {
        let store = SettingsStore.shared
        self.settings = store.settings
        self.sttKey = store.sttAPIKey(for: store.settings.stt.provider) ?? ""
        self.llmKey = store.llmAPIKey ?? ""
        refreshDevices()
    }

    // 키 테스트 상태
    @Published var sttTestResult: String?
    @Published var llmTestResult: String?
    @Published var sttTesting = false
    @Published var llmTesting = false

    // MARK: - STT 엔진

    var currentSTTPresetName: String {
        if settings.stt.provider != .custom {
            return STTPresets.all.first(where: { $0.provider == settings.stt.provider })?.name
                ?? settings.stt.provider.rawValue
        }
        let ep = settings.stt.customEndpoint
        if !ep.isEmpty, let match = STTPresets.all.first(where: { $0.customEndpoint == ep }) {
            return match.name
        }
        return "Custom"
    }

    /// provider별 API 키 발급 페이지
    func sttKeyIssueURL() -> URL? {
        switch settings.stt.provider {
        case .soniox: return URL(string: "https://console.soniox.com/")
        case .deepgram: return URL(string: "https://console.deepgram.com/")
        case .custom: return nil
        }
    }

    func llmKeyIssueURL() -> URL? {
        let ep = settings.llm.endpoint
        if LLMPresets.isLocalEndpoint(ep) { return nil }
        if ep.contains("deepseek") { return URL(string: "https://platform.deepseek.com/api_keys") }
        if ep.contains("groq") { return URL(string: "https://console.groq.com/keys") }
        if ep.contains("openai") { return URL(string: "https://platform.openai.com/api-keys") }
        if ep.contains("googleapis") { return URL(string: "https://aistudio.google.com/apikey") }
        if ep.contains("x.ai") { return URL(string: "https://console.x.ai/") }
        if ep.contains("anthropic") { return URL(string: "https://console.anthropic.com/settings/keys") }
        if ep.contains("openrouter") { return URL(string: "https://openrouter.ai/keys") }
        return nil
    }

    func testSTTKey() {
        sttTesting = true
        sttTestResult = nil
        let provider = settings.stt.provider
        let key = sttKey
        let custom = settings.stt.customEndpoint
        Task { @MainActor in
            let r = await KeyTester.testSTT(provider: provider, apiKey: key, customEndpoint: custom)
            switch r {
            case .ok(let m): self.sttTestResult = "✅ " + m
            case .fail(let m): self.sttTestResult = "⚠️ " + m
            }
            self.sttTesting = false
        }
    }

    func testLLMKey() {
        llmTesting = true
        llmTestResult = nil
        let cfg = settings.llm
        let key = llmNeedsAPIKey ? llmKey : nil
        Task { @MainActor in
            let r = await KeyTester.testLLM(config: cfg, apiKey: key)
            switch r {
            case .ok(let m): self.llmTestResult = "✅ " + m
            case .fail(let m): self.llmTestResult = "⚠️ " + m
            }
            self.llmTesting = false
        }
    }

    func selectSTTProvider(_ provider: STTProvider) {
        settings.stt.provider = provider
        // 키 입력란을 해당 provider 키로 갱신
        sttKey = SettingsStore.shared.sttAPIKey(for: provider) ?? ""
    }

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    private func persist() {
        SettingsStore.shared.update { $0 = settings }
        onProfilesChange?()   // 단축키 재등록 (저렴)
    }

    // 언어 힌트 (쉼표 문자열 ↔ 배열)
    var languageHintsText: String {
        get { settings.languageHints.joined(separator: ", ") }
        set {
            settings.languageHints = newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - LLM 프리셋

    func applySTTPreset(_ preset: STTPreset) {
        settings.stt.provider = preset.provider
        if let ep = preset.customEndpoint {
            settings.stt.customEndpoint = ep
        } else if preset.provider == .custom {
            // "Custom" 선택 — endpoint 필드 비워서 직접 입력 유도
            settings.stt.customEndpoint = ""
        }
        sttKey = SettingsStore.shared.sttAPIKey(for: preset.provider) ?? ""
    }

    /// 현재 endpoint에 매칭되는 프리셋 이름
    var currentLLMPresetName: String {
        LLMPresets.match(endpoint: settings.llm.endpoint).name
    }

    var currentLLMPreset: LLMPreset {
        LLMPresets.match(endpoint: settings.llm.endpoint)
    }

    var llmNeedsAPIKey: Bool {
        currentLLMPreset.requiresAPIKey
    }

    var llmUsesLocalEndpoint: Bool {
        LLMPresets.isLocalEndpoint(settings.llm.endpoint)
    }

    var suggestedLocalModels: [String] {
        LLMPresets.suggestedLocalModels
    }

    func applyLLMPreset(_ preset: LLMPreset) {
        guard !preset.isCustom else { return }  // 커스텀은 직접 입력 유지
        settings.llm.endpoint = preset.endpoint
        settings.llm.model = preset.defaultModel
        llmTestResult = nil
    }

    func selectLocalLLMModel(_ model: String) {
        settings.llm.model = model
    }

    // MARK: - 프로파일 CRUD

    func addProfile(named name: String) {
        settings.profiles.append(PromptProfile(name: name,
                                               hotkeyKeyCode: 0,
                                               useLLM: true,
                                               instruction: ""))
    }

    func removeProfile(_ id: UUID) {
        settings.profiles.removeAll { $0.id == id }
        if settings.spaceBarProfileID == id {
            settings.spaceBarProfileID = nil
        }
    }

    func profileHotkeyDisplay(_ p: PromptProfile, unassignedLabel: String) -> String {
        p.hotkeyKeyCode == 0 ? unassignedLabel : KeyNames.display(keyCode: p.hotkeyKeyCode, modifiers: p.hotkeyModifiers)
    }

    var selectedSpaceBarProfileID: UUID? {
        get { settings.spaceBarProfileID }
        set { settings.spaceBarProfileID = newValue }
    }

    var selectedSpaceBarProfileName: String {
        guard let id = settings.spaceBarProfileID,
              let profile = settings.profiles.first(where: { $0.id == id }) else {
            return settings.profiles.first?.name ?? ""
        }
        return profile.name
    }

    /// 현재 실행 중인 일반 앱 목록 (VoiceType 자신·이미 제외된 앱 필터)
    var runningAppsForExclusion: [AppExclusionItem] {
        let myID = Bundle.main.bundleIdentifier ?? ""
        let excluded = Set(settings.spaceBarExcludedAppBundleIDs)
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bid = app.bundleIdentifier,
                      app.activationPolicy == .regular,
                      bid != myID,
                      !excluded.contains(bid) else { return false }
                return true
            }
            .compactMap { app -> AppExclusionItem? in
                guard let bid = app.bundleIdentifier else { return nil }
                return AppExclusionItem(id: bid, name: app.localizedName ?? bid, bundleID: bid)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var excludedSpaceBarApps: [AppExclusionItem] {
        settings.spaceBarExcludedAppBundleIDs.map { bundleID in
            AppExclusionItem(id: bundleID,
                             name: appDisplayName(for: bundleID),
                             bundleID: bundleID)
        }
    }

    func addSpaceBarExcludedApp(bundleID: String) {
        guard !bundleID.isEmpty,
              !settings.spaceBarExcludedAppBundleIDs.contains(bundleID) else { return }
        settings.spaceBarExcludedAppBundleIDs.append(bundleID)
    }

    func removeSpaceBarExcludedApp(bundleID: String) {
        settings.spaceBarExcludedAppBundleIDs.removeAll { $0 == bundleID }
    }

    /// NSOpenPanel로 /Applications에서 앱 직접 선택
    func browseAndAddApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "앱 선택"
        panel.prompt = "제외 추가"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
            addSpaceBarExcludedApp(bundleID: bid)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            return displayName ?? name ?? bundleID
        }
        return bundleID
    }

    // MARK: - 마이크 우선순위

    func deviceName(for uid: String) -> String {
        devices.first(where: { $0.id == uid })?.name ?? uid
    }

    func selectMicrophone(_ uid: String?) {
        settings.selectedMicrophoneUID = uid
    }

    func addToPriority(_ uid: String) {
        if !settings.microphonePriority.contains(uid) {
            settings.microphonePriority.append(uid)
        }
    }
    func removeFromPriority(at offsets: IndexSet) {
        let removed = offsets.compactMap { settings.microphonePriority.indices.contains($0) ? settings.microphonePriority[$0] : nil }
        settings.microphonePriority.remove(atOffsets: offsets)
        if let selected = settings.selectedMicrophoneUID, removed.contains(selected) {
            settings.selectedMicrophoneUID = nil
        }
    }
    func movePriority(from: IndexSet, to: Int) {
        settings.microphonePriority.move(fromOffsets: from, toOffset: to)
    }
    func movePriority(at index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.microphonePriority.indices.contains(index),
              settings.microphonePriority.indices.contains(destination) else { return }
        settings.microphonePriority.swapAt(index, destination)
    }
    func isDeviceConnected(_ uid: String) -> Bool {
        devices.contains { $0.id == uid }
    }

    var selectedMicrophoneName: String {
        guard let uid = settings.selectedMicrophoneUID else { return "" }
        return deviceName(for: uid)
    }

    var selectedMicrophoneConnected: Bool {
        guard let uid = settings.selectedMicrophoneUID else { return false }
        return isDeviceConnected(uid)
    }

    var selectedMicrophoneUnavailable: Bool {
        settings.selectedMicrophoneUID != nil && !selectedMicrophoneConnected
    }

    /// 실제 받아쓰기와 같은 규칙: 명시 선택이 연결되어 있으면 우선 사용,
    /// 아니면 연결된 우선순위 장치, 마지막으로 시스템 기본 입력을 사용한다.
    var activeInputDeviceID: AudioDeviceID? {
        AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                             priority: settings.microphonePriority)?.deviceID
    }
    var activeInputDeviceName: String {
        if let selectedUID = settings.selectedMicrophoneUID,
           let device = devices.first(where: { $0.id == selectedUID }) {
            return device.name
        }
        for uid in settings.microphonePriority {
            if let device = devices.first(where: { $0.id == uid }) {
                return device.name
            }
        }
        if let defaultID = AudioDevices.defaultInputDevice(),
           let device = devices.first(where: { $0.deviceID == defaultID }) {
            return device.name
        }
        return "macOS 기본 마이크"
    }

    var activeInputUsesExplicitSelection: Bool {
        guard let selectedUID = settings.selectedMicrophoneUID else { return false }
        return devices.contains { $0.id == selectedUID }
    }

    var availableToAdd: [AudioInputDevice] {
        devices.filter { !settings.microphonePriority.contains($0.id) }
    }

    // MARK: - 프로파일 단축키 캡처

    func startCapturingHotkey(for id: UUID) {
        capturingProfileID = id
        // 실제 캡처는 HotkeyCaptureView(NSView.keyDown)가 담당 — monitor 불필요
    }

    func stopCapturingHotkey() {
        capturingProfileID = nil
    }

    func applyHotkey(keyCode: UInt32, modifiers: UInt32, for id: UUID) {
        guard let idx = settings.profiles.firstIndex(where: { $0.id == id }) else { return }
        settings.profiles[idx].hotkeyKeyCode = keyCode
        settings.profiles[idx].hotkeyModifiers = modifiers
        stopCapturingHotkey()
    }
}
