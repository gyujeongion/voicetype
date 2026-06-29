import SwiftUI
import AppKit
import VoiceTypeCore

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject var history = HistoryStore.shared
    @EnvironmentObject var localization: LocalizationManager
    @StateObject private var micTester = MicTester()

    private func t(_ key: String.LocalizationValue) -> String {
        localization.text(key)
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label(t("tab.general"), systemImage: "gearshape") }
            promptsTab.tabItem { Label(t("tab.prompts"), systemImage: "wand.and.stars") }
            dictionaryTab.tabItem { Label(t("tab.vocabulary"), systemImage: "character.book.closed") }
            historyTab.tabItem { Label(t("tab.history"), systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 580, height: 640)
        .padding()
    }

    // MARK: - 일반

    private var generalTab: some View {
        Form {
            Section(t("stt.section")) {
                HStack(spacing: 6) {
                    Text(t("stt.engine")).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(STTPresets.all) { preset in
                            Button { vm.applySTTPreset(preset) } label: {
                                if preset.isRecommended {
                                    Label(preset.name, systemImage: "star.fill")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            let isRec = STTPresets.all.first(where: { $0.name == vm.currentSTTPresetName })?.isRecommended == true
                            if isRec {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption2)
                            }
                            Text(vm.currentSTTPresetName)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)

                    Button { sttInfoVisible.toggle() } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $sttInfoVisible, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(t("stt.info.title")).font(.headline)
                            Text(t("stt.info.body")).font(.callout)
                        }
                        .padding(16)
                        .frame(width: 300)
                    }
                }
                if let noteKey = STTPresets.all.first(where: { $0.name == vm.currentSTTPresetName })?.noteKey {
                    Text(localization.text(noteKey)).font(.caption).foregroundStyle(.secondary)
                }
                if vm.settings.stt.provider == .custom {
                    TextField(t("stt.custom.endpoint"), text: $vm.settings.stt.customEndpoint)
                }
                SecureField("\(vm.currentSTTPresetName) \(t("stt.apikey"))", text: $vm.sttKey)
                HStack {
                    if let url = vm.sttKeyIssueURL() {
                        Link(t("stt.getkey"), destination: url).font(.caption)
                    }
                    Spacer()
                    Button(vm.sttTesting ? t("stt.testing") : t("stt.testkey")) { vm.testSTTKey() }
                        .font(.caption).disabled(vm.sttTesting || vm.sttKey.isEmpty)
                }
                if let r = vm.sttTestResult {
                    Text(r).font(.caption).foregroundStyle(r.hasPrefix("✅") ? .green : .orange)
                }
                Text(t("stt.keychain.note"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(t("stt.language.hints"), text: Binding(
                    get: { vm.languageHintsText },
                    set: { vm.languageHintsText = $0 }))
            }

            Section(t("llm.section")) {
                Text(t("llm.required.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledRow(t("prompts.llm.provider")) {
                    Menu(vm.currentLLMPresetName) {
                        ForEach(LLMPresets.all) { preset in
                            Button(preset.name) { vm.applyLLMPreset(preset) }
                        }
                    }
                }

                if !vm.currentLLMPreset.note.isEmpty {
                    Text(vm.currentLLMPreset.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                LabeledRow(t("prompts.llm.endpoint")) {
                    TextField(vm.llmUsesLocalEndpoint ? "http://127.0.0.1:11434/v1/chat/completions" : "https://…/v1/chat/completions",
                              text: $vm.settings.llm.endpoint)
                }

                LabeledRow(t("prompts.llm.model")) {
                    TextField(t("prompts.llm.model"), text: $vm.settings.llm.model)
                }

                if vm.llmUsesLocalEndpoint {
                    HStack {
                        Text(t("llm.local.models"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu(t("llm.local.models")) {
                            ForEach(vm.suggestedLocalModels, id: \.self) { model in
                                Button(model) { vm.selectLocalLLMModel(model) }
                            }
                        }
                    }
                    Text(t("llm.local.note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                LabeledRow(vm.llmNeedsAPIKey ? t("prompts.llm.apikey") : t("llm.apikey.optional")) {
                    SecureField(vm.llmUsesLocalEndpoint ? t("llm.apikey.placeholder.optional") : "sk-…", text: $vm.llmKey)
                }

                HStack {
                    if let url = vm.llmKeyIssueURL() {
                        Link(t("prompts.getkey"), destination: url).font(.caption)
                    }
                    Spacer()
                    Button(vm.llmTesting ? t("prompts.testing") : t("prompts.testkey")) { vm.testLLMKey() }
                        .font(.caption)
                        .disabled(vm.llmTesting || (vm.llmNeedsAPIKey && vm.llmKey.isEmpty))
                }
                if let r = vm.llmTestResult {
                    Text(r).font(.caption).foregroundStyle(r.hasPrefix("✅") ? .green : .orange)
                }
                Text(t("prompts.llm.preset.note"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section(t("mic.section")) {
                Picker(t("mic.source"), selection: Binding(
                    get: { vm.settings.selectedMicrophoneUID },
                    set: { vm.selectMicrophone($0) }
                )) {
                    Text(t("mic.auto.option")).tag(String?.none)
                    ForEach(vm.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                    if vm.selectedMicrophoneUnavailable,
                       let selectedUID = vm.settings.selectedMicrophoneUID {
                        Text("\(vm.selectedMicrophoneName) (\(t("mic.unavailable.short")))")
                            .tag(Optional(selectedUID))
                    }
                }

                if vm.selectedMicrophoneUnavailable {
                    Text(t("mic.fallback.note"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Label(t("mic.active"), systemImage: "mic")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(vm.activeInputDeviceName)
                        .lineLimit(1)
                }

                Text(vm.activeInputUsesExplicitSelection ? t("mic.active.selected") : t("mic.active.auto"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MicLevelIndicator(
                    level: micTester.samples.last ?? 0,
                    peakDB: micTester.peakDB,
                    isRunning: micTester.isRunning,
                    errorMessage: micTester.errorMessage
                )

                HStack {
                    Button(micTester.isRunning ? t("mic.monitor.stop") : t("mic.monitor.start")) {
                        if micTester.isRunning {
                            micTester.stop()
                        } else {
                            micTester.start(deviceID: vm.activeInputDeviceID)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                    Text(t("mic.monitor.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text(t("mic.priority.title"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        vm.refreshDevices()
                        if micTester.isRunning {
                            micTester.start(deviceID: vm.activeInputDeviceID)
                        }
                    } label: {
                        Label(t("mic.refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                if vm.settings.microphonePriority.isEmpty {
                    Text(t("mic.priority.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(vm.settings.microphonePriority.enumerated()), id: \.element) { idx, uid in
                        HStack {
                            Text("\(idx + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(vm.deviceName(for: uid))
                                .lineLimit(1)
                            if !vm.isDeviceConnected(uid) {
                                Text(t("mic.unavailable.short"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                vm.movePriority(at: idx, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx == 0)

                            Button {
                                vm.movePriority(at: idx, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx == vm.settings.microphonePriority.count - 1)

                            Button(role: .destructive) {
                                vm.removeFromPriority(at: IndexSet(integer: idx))
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack {
                    Menu {
                        ForEach(vm.availableToAdd) { dev in
                            Button(dev.name) { vm.addToPriority(dev.id) }
                        }
                    } label: {
                        Label(t("mic.add"), systemImage: "plus")
                    }
                    .disabled(vm.availableToAdd.isEmpty)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: vm.settings.microphonePriority) {
                if micTester.isRunning {
                    micTester.start(deviceID: vm.activeInputDeviceID)
                }
            }
            .onChange(of: vm.settings.selectedMicrophoneUID) {
                if micTester.isRunning {
                    micTester.start(deviceID: vm.activeInputDeviceID)
                }
            }
            .onDisappear { micTester.stop() }

            Section(t("output.section")) {
                Toggle(t("output.autopaste"), isOn: $vm.settings.autoPaste)
                Text(t("output.autopaste.note"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(t("output.accessibility"))
                        .font(.caption)
                    Spacer()
                    Button(t("output.accessibility.open")) {
                        TextInjector.promptAccessibility()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
                Text(t("output.accessibility.note"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section(t("output.space.section")) {
                Toggle(t("output.space.toggle"), isOn: $vm.settings.spaceBarTrigger)
                if vm.settings.spaceBarTrigger {
                    Picker(t("output.space.profile"), selection: Binding(
                        get: { vm.selectedSpaceBarProfileID },
                        set: { vm.selectedSpaceBarProfileID = $0 }
                    )) {
                        ForEach(vm.settings.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    Stepper(
                        t("output.space.sensitivity") + ": \(vm.settings.spaceBarThreshold)",
                        value: $vm.settings.spaceBarThreshold,
                        in: 2...8
                    )
                    HStack {
                        Text(t("output.space.excluded"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        // 실행 중인 앱에서 선택
                        Menu {
                            if vm.runningAppsForExclusion.isEmpty {
                                Text(t("output.space.no_running")).foregroundStyle(.secondary)
                            } else {
                                ForEach(vm.runningAppsForExclusion) { app in
                                    Button(app.name) {
                                        vm.addSpaceBarExcludedApp(bundleID: app.bundleID)
                                    }
                                }
                            }
                        } label: {
                            Label(t("output.space.add_running"), systemImage: "plus")
                        }
                        // 응용 프로그램 폴더에서 직접 선택
                        Button { vm.browseAndAddApp() } label: {
                            Image(systemName: "folder")
                        }
                        .help(t("output.space.browse"))
                        .buttonStyle(.borderless)
                    }
                    if vm.excludedSpaceBarApps.isEmpty {
                        Text(t("output.space.excluded.empty"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.excludedSpaceBarApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    vm.removeSpaceBarExcludedApp(bundleID: app.bundleID)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Text(t("output.space.note"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(t("language.section")) {
                Picker(t("language.picker"), selection: $localization.selectedID) {
                    ForEach(LocalizationManager.supported) { lang in
                        Text("\(lang.flag) \(lang.displayName)").tag(lang.id)
                    }
                }
                // Locale re-injection is handled by LocaleObservingSettings via .id(selectedID)
            }

            Section(t("diag.section")) {
                HStack {
                    Text(t("diag.note"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(diagCopied ? t("diag.copied") : t("diag.copy")) {
                        Diagnostics.copyToClipboard()
                        diagCopied = true
                    }.font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    @State private var diagCopied = false
    @State private var sttInfoVisible = false

    // MARK: - 프롬프트 (프로파일 + 단축키)

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("prompts.title"))
                .font(.headline)
            Text(t("prompts.note"))
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($vm.settings.profiles) { $profile in
                        ProfileCard(profile: $profile, vm: vm)
                    }
                }
                .padding(.vertical, 4)
            }

            Button { vm.addProfile(named: t("prompts.add")) } label: { Label(t("prompts.add"), systemImage: "plus") }

            Divider().padding(.vertical, 4)
            Text(t("prompts.llm.moved.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - 단어사전

    private var dictionaryTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("vocab.title"))
                .font(.headline)
            Text(t("vocab.note"))
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $vm.settings.dictionary.rawText)
                .font(.body)
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))

            Text(t("vocab.example"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String.localizedStringWithFormat(t("vocab.count"), vm.settings.dictionary.hintTerms().count))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - 히스토리

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("history.title")).font(.headline)
                Spacer()
                if !history.entries.isEmpty {
                    Button(t("history.delete.all"), role: .destructive) { history.clear() }
                        .font(.caption)
                }
            }
            Text(t("history.note"))
                .font(.caption).foregroundStyle(.secondary)

            if history.entries.isEmpty {
                Spacer()
                Text(t("history.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry,
                                   onCopy: { TextInjector.copyToClipboard(entry.finalText) },
                                   onDelete: { history.delete(entry.id) })
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - 프로파일 카드

private struct ProfileCard: View {
    @Binding var profile: PromptProfile
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject var localization: LocalizationManager

    private func t(_ key: String.LocalizationValue) -> String {
        localization.text(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(t("prompts.profile.name"), text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)

                Button(vm.capturingProfileID == profile.id ? t("prompts.profile.hotkey.cancel") : vm.profileHotkeyDisplay(profile, unassignedLabel: t("prompts.profile.unassigned"))) {
                    if vm.capturingProfileID == profile.id { vm.stopCapturingHotkey() }
                    else { vm.startCapturingHotkey(for: profile.id) }
                }
                .frame(minWidth: 110)
                // 캡처 모드일 때 NSView가 first responder를 가져가 keyDown을 직접 수신
                .background(
                    Group {
                        if vm.capturingProfileID == profile.id {
                            HotkeyCaptureView(
                                onCapture: { keyCode, mods in
                                    vm.applyHotkey(keyCode: keyCode, modifiers: mods, for: profile.id)
                                },
                                onCancel: { vm.stopCapturingHotkey() }
                            )
                            .opacity(0)  // 보이지 않지만 크기 유지 → first responder 획득 가능
                        }
                    }
                )

                Picker("", selection: $profile.triggerMode) {
                    Text(t("prompts.trigger.toggle")).tag(TriggerMode.toggle)
                    Text(t("prompts.trigger.hold")).tag(TriggerMode.pushToTalk)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .help(t("prompts.trigger.help"))

                Spacer()

                Toggle(t("prompts.llm.toggle"), isOn: $profile.useLLM)
                    .toggleStyle(.switch)

                Button(role: .destructive) {
                    vm.removeProfile(profile.id)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }

            if profile.useLLM {
                TextEditor(text: $profile.instruction)
                    .frame(height: 70)
                    .font(.callout)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
                Text(t("prompts.llm.example"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(t("prompts.llm.off.note"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onCopy: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var localization: LocalizationManager
    @State private var showRaw = false
    @State private var copied = false

    private func t(_ key: String.LocalizationValue) -> String {
        localization.text(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(entry.profileName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                if !entry.autoPasted {
                    Text(t("history.unpasted"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // 최종본 (실제 붙여넣으려던 내용)
            Text(entry.finalText.isEmpty ? t("history.empty.result") : entry.finalText)
                .font(.body)
                .textSelection(.enabled)

            // 원문 (LLM 거치기 전) — 다를 때만
            if entry.wasProcessed {
                Button(showRaw ? t("history.raw.hide") : t("history.raw.show")) { showRaw.toggle() }
                    .font(.caption2).buttonStyle(.borderless)
                if showRaw {
                    Text(entry.rawTranscript)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.08)))
                }
            }

            HStack {
                Button { onCopy(); copied = true } label: {
                    Label(copied ? t("history.copied") : t("history.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .font(.caption).buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }
    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }
}
