import SwiftUI
import AppKit
import AVFoundation
import VoiceTypeCore

/// 첫 실행 온보딩 윈도우 관리.
@MainActor
final class OnboardingController {
    static let doneKey = "voicetype.onboarded.v1"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }

    private var window: NSWindow?
    var onFinish: (() -> Void)?

    func show() {
        let lm = LocalizationManager.shared
        let view = OnboardingView(onDone: { [weak self] in
            OnboardingController.markDone()
            self?.window?.close()
            self?.window = nil
            self?.onFinish?()
        })
        .environment(\.locale, lm.activeLocale)
        .environmentObject(lm)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = lm.text("onboarding.window.title")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        NSApp.setActivationPolicy(.regular) // 온보딩 동안 Dock·창 포커스 허용
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var localization: LocalizationManager
    var onDone: () -> Void

    @State private var step = 0
    private let totalSteps = 5

    @State private var selectedPresetName = "Soniox"
    @State private var sttKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private func t(_ key: String.LocalizationValue) -> String {
        localization.text(key)
    }

    private var selectedPreset: STTPreset {
        STTPresets.all.first(where: { $0.name == selectedPresetName })
            ?? STTPresets.all.first(where: { $0.provider == .soniox })
            ?? STTPresets.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 진행 표시
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding()

            Group {
                switch step {
                case 0: welcome
                case 1: micStep
                case 2: accessibilityStep
                case 3: keyStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)

            Divider()
            HStack {
                if step > 0 && step < totalSteps - 1 {
                    Button(t("onboarding.btn.prev")) { step -= 1 }
                }
                Spacer()
                nextButton
            }
            .padding()
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - 단계

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text(t("onboarding.welcome.title")).font(.title2).bold()
            Text(t("onboarding.welcome.subtitle"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label(t("onboarding.welcome.free"), systemImage: "checkmark.seal")
                Label(t("onboarding.welcome.key"), systemImage: "key")
                Label(t("onboarding.welcome.cost"), systemImage: "creditcard")
            }
            .font(.callout)
            .padding().background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        }
    }

    private var micStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text(t("onboarding.mic.title")).font(.title3).bold()
            Text(t("onboarding.mic.subtitle"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            switch micStatus {
            case .authorized:
                Label(t("onboarding.mic.granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied, .restricted:
                VStack(spacing: 8) {
                    Label(t("onboarding.mic.denied"), systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                    Button(t("onboarding.mic.open")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            default:
                Button(t("onboarding.mic.request")) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.point.up.left.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text(t("onboarding.ax.title")).font(.title3).bold()
            Text(t("onboarding.ax.subtitle"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(t("onboarding.ax.open")) {
                TextInjector.promptAccessibility()
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(u)
                }
            }.buttonStyle(.borderedProminent)
            Text(t("onboarding.ax.note"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("onboarding.key.title")).font(.title3).bold()
            Text(t("onboarding.key.subtitle"))
                .foregroundStyle(.secondary)

            Picker(t("onboarding.key.engine"), selection: $selectedPresetName) {
                ForEach(STTPresets.all.filter(\.isRecommended)) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }.pickerStyle(.segmented)

            HStack {
                Link(t("onboarding.key.getkey"), destination: issueURL).font(.callout)
                Spacer()
            }
            SecureField(t("onboarding.key.paste"), text: $sttKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(testing ? t("onboarding.key.testing") : t("onboarding.key.test")) { runTest() }
                    .disabled(testing || sttKey.isEmpty)
                if let r = testResult {
                    Text(r).font(.callout).foregroundStyle(r.hasPrefix("✅") ? .green : .orange)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text(t("onboarding.done.title")).font(.title2).bold()
            VStack(alignment: .leading, spacing: 8) {
                Label(t("onboarding.done.hint1"), systemImage: "1.circle")
                Label(t("onboarding.done.hint2"), systemImage: "2.circle")
                Label(t("onboarding.done.hint3"), systemImage: "3.circle")
            }
            .font(.callout)
            .padding().background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            Text(t("onboarding.done.note"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: - 로직

    private var issueURL: URL {
        switch selectedPreset.provider {
        case .soniox: return URL(string: "https://console.soniox.com/")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        case .custom: return URL(string: "https://soniox.com/")!
        }
    }

    private func runTest() {
        testing = true; testResult = nil
        let provider = selectedPreset.provider
        let key = sttKey
        Task { @MainActor in
            let r = await KeyTester.testSTT(provider: provider, apiKey: key, customEndpoint: nil)
            switch r {
            case .ok(let m): testResult = "✅ " + m
            case .fail(let m): testResult = "⚠️ " + m
            }
            testing = false
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        switch step {
        case 3:
            Button(t("onboarding.btn.save")) {
                if !sttKey.isEmpty {
                    SettingsStore.shared.update { $0.stt.provider = selectedPreset.provider }
                    SettingsStore.shared.setSTTAPIKey(sttKey, for: selectedPreset.provider)
                }
                step += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(sttKey.isEmpty)
        case totalSteps - 1:
            Button(t("onboarding.btn.start")) { onDone() }.buttonStyle(.borderedProminent)
        default:
            Button(t("onboarding.btn.next")) { step += 1 }.buttonStyle(.borderedProminent)
        }
    }
}
