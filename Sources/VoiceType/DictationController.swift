import Foundation
import VoiceTypeCore

/// 받아쓰기 전체 흐름 제어: idle → starting → recording → finishing → (주입) → idle
@MainActor
final class DictationController {
    enum State { case idle, starting, recording, finishing }

    private(set) var state: State = .idle
    private let capture = AudioCapture()
    private var engine: STTEngine?
    /// 현재 녹음 중인 프로파일 (종료 시 이 프로파일로 후처리)
    private var activeProfile: PromptProfile?
    /// Accessibility 권한 안내를 이미 띄웠는지 (반복 방지)
    private static var accessibilityWarned = false
    /// finish 후 STT 응답 지연 가드
    private var finishTimeout: Task<Void, Never>?

    var onStateChange: ((State) -> Void)?
    var onInterim: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// 마이크 입력 레벨(RMS 0~1) — 인디케이터 레벨미터용
    var onLevel: ((Float) -> Void)?

    /// 핫키를 눌렀을 때. idle → 시작, recording → toggle 모드에서만 종료.
    func trigger(profile: PromptProfile) {
        switch state {
        case .idle:     start(profile: profile)
        case .starting: break   // 권한 요청 중 — 무시 (debounce)
        case .recording:
            if profile.triggerMode == .toggle { finish() }
            // pushToTalk: 키를 놓을 때(release) 종료 — 여기선 무시
        case .finishing: break  // 처리 중 — 무시
        }
    }

    /// 핫키를 뗐을 때. push-to-talk 모드에서만 녹음 종료.
    func release(profile: PromptProfile) {
        guard profile.triggerMode == .pushToTalk else { return }
        if state == .recording { finish() }
    }

    // MARK: - 시작

    private func start(profile: PromptProfile) {
        setState(.starting)   // block re-entry during async permission request
        let store = SettingsStore.shared
        let provider = store.settings.stt.provider
        guard let apiKey = store.sttAPIKey(for: provider), !apiKey.isEmpty else {
            onError?("\(STTPresets.name(for: provider)) API 키가 설정되지 않았습니다. 설정 > 일반에서 키를 입력하세요.")
            setState(.idle)
            return
        }
        activeProfile = profile
        AudioCapture.requestPermission { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard ok else {
                    self.onError?("마이크 권한이 거부되었습니다. 시스템 설정 > 개인정보 보호 > 마이크에서 허용하세요.")
                    self.setState(.idle)
                    return
                }
                self.beginRecording(apiKey: apiKey, settings: store.settings)
            }
        }
    }

    private func beginRecording(apiKey: String, settings: AppSettings) {
        let engine = STTEngineFactory.make(settings.stt)
        self.engine = engine

        engine.onUpdate = { [weak self] f, i in
            self?.onInterim?(f + i)
        }
        engine.onError = { [weak self] err in
            guard let self = self else { return }
            self.cleanup()
            self.setState(.idle)
            self.onError?(KeyTester.networkMessage(err))
        }
        engine.onFinished = { [weak self] text in
            self?.handleFinal(text: text, settings: settings)
        }

        let customEndpoint = settings.stt.provider == .custom ? settings.stt.customEndpoint : nil
        engine.start(apiKey: apiKey,
                     languageHints: settings.languageHints,
                     terms: settings.dictionary.hintTerms(),
                     customEndpoint: customEndpoint)
        capture.onPCM = { [weak engine] data in engine?.sendAudio(data) }
        capture.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onLevel?(level) }
        }

        // 우선순위 목록에 일치하는 장치 없으면 nil → AVAudioEngine이 시스템 기본 입력 자동 사용
        // (USB 마이크 등 외부 장치가 시스템 기본값이면 자동으로 잡힘)
        let device = AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                                          priority: settings.microphonePriority)
        do {
            try capture.start(deviceID: device?.deviceID)
            setState(.recording)
        } catch {
            engine.cancel()
            self.engine = nil
            capture.onPCM = nil
            onError?("녹음 시작 실패: \(error.localizedDescription)")
            setState(.idle)
        }
    }

    // MARK: - 종료

    private func finish() {
        setState(.finishing)
        capture.stop()
        engine?.finish()
        // 결과는 engine.onFinished 로 도착 — 안 오면 타임아웃으로 복구
        finishTimeout?.cancel()
        finishTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self = self, self.state == .finishing else { return }
            self.engine?.cancel()
            self.cleanup()
            self.setState(.idle)
            self.onError?("STT 응답이 지연되어 종료했습니다. 네트워크 또는 키를 확인하세요.")
        }
    }

    private func handleFinal(text: String, settings: AppSettings) {
        capture.stop()
        let store = SettingsStore.shared
        let profile = activeProfile
        let raw = text
        Task { @MainActor in
            var out = text
            var pasted = false
            // 프로파일이 LLM 사용 시에만 후처리 (번역/요약/정리 등)
            if let profile = profile, profile.useLLM {
                out = await PostProcessRunner.run(transcript: out,
                                                  instruction: profile.instruction,
                                                  llm: settings.llm,
                                                  apiKey: store.llmAPIKey,
                                                  glossary: settings.dictionary.hintTerms())
            }
            // 단어사전은 STT context.terms 로 인식 단계에서 이미 교정됨 (별도 후처리 불필요)
            if !out.isEmpty {
                // 결과는 항상 클립보드에 복사됨 (놓쳐도 Cmd+V 가능)
                pasted = TextInjector.injectText(out, autoPaste: settings.autoPaste)
                // autoPaste인데 권한이 없어 못 붙인 경우 1회 안내 + 시스템 설정 유도
                if settings.autoPaste && !pasted && !TextInjector.hasAccessibility() && !Self.accessibilityWarned {
                    Self.accessibilityWarned = true
                    TextInjector.promptAccessibility()
                    self.onError?("자동 붙여넣기엔 '손쉬운 사용(Accessibility)' 권한이 필요합니다.\n시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 VoiceType을 켠 뒤 앱을 다시 실행하세요.\n(지금은 클립보드에 복사됨 — Cmd+V로 붙여넣으세요)")
                }
            }
            // 히스토리 기록 (원문 + 최종본)
            if !raw.isEmpty || !out.isEmpty {
                HistoryStore.shared.add(profileName: profile?.name ?? "받아쓰기",
                                        raw: raw,
                                        final: out,
                                        autoPasted: pasted)
            }
            self.cleanup()
            self.setState(.idle)
        }
    }

    private func cleanup() {
        finishTimeout?.cancel()
        finishTimeout = nil
        capture.stop()
        capture.onPCM = nil
        capture.onLevel = nil
        engine = nil
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }
}
