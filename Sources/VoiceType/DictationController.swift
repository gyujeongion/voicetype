import AppKit
import Foundation
import VoiceTypeCore

/// 받아쓰기 전체 흐름 제어: idle → starting → recording → finishing → (주입) → idle
@MainActor
final class DictationController {
    enum State { case idle, starting, recording, finishing }

    private(set) var state: State = .idle
    /// F5 녹음과의 마이크 점유 충돌을 막기 위해 외부(AppDelegate)에서 확인하는 값.
    var isActive: Bool { state != .idle }
    private let capture = AudioCapture()
    private var engine: STTEngine?
    /// 현재 녹음 중인 프로파일 (종료 시 이 프로파일로 후처리)
    private var activeProfile: PromptProfile?
    /// 이번 세션의 원본 오디오(m4a) 목적지. 히스토리에 붙지 못하면 cleanup()에서 삭제.
    private var activeRecordingURL: URL?
    /// 녹음을 시작할 때 맨 앞에 있던 앱. 결과를 다시 그 앱에만 자동 주입하기 위해 기억해둔다 —
    /// 처리 중 사용자가 다른 앱으로 옮겨가면 엉뚱한 곳에 붙여넣기되는 사고를 막는다.
    private var startedInAppBundleID: String?
    /// Accessibility 권한 안내를 이미 띄웠는지 (반복 방지)
    private static var accessibilityWarned = false
    /// finish 후 STT 응답 지연 가드
    private var finishTimeout: Task<Void, Never>?
    /// 이번 세션의 식별자. 취소·타임아웃 이후 늦게 도착하는 옛 엔진의 콜백(지연·중복 응답)을
    /// 걸러내는 데 쓴다 — 없으면 옛 세션의 텍스트가 새 세션의 프로파일/녹음파일에 잘못 붙는다.
    private var sessionToken: UUID?

    var onStateChange: ((State) -> Void)?
    var onInterim: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// 흐름은 계속되지만 사용자가 알아야 하는 일(후처리 실패 등) — 비차단 알림용
    var onNotice: ((String) -> Void)?
    /// 사용자가 설정을 바꿔야만 풀리는 문제 (권한·키) — 해결 버튼이 달린 창으로 보여준다
    var onActionNeeded: ((UserActionNeeded) -> Void)?
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

    var isRecording: Bool { state == .recording }

    /// 메뉴·외부에서 녹음 종료. 꾹누르기(push-to-talk) 프로파일은 키를 떼야 끝나므로
    /// 메뉴로는 끝낼 방법이 없었다 — 이 경로가 그걸 풀어준다.
    func stop() {
        if state == .recording { finish() }
    }

    /// 녹음·처리를 취소한다. 결과를 붙여넣지 않고 클립보드도 건드리지 않으며 히스토리에도 남기지 않는다.
    /// (말실수·잘못 누름·엉뚱한 앱에 포커스된 경우 쓰레기 텍스트가 붙는 걸 막는다)
    func cancel() {
        guard state == .recording || state == .finishing else { return }
        // 세션 토큰을 먼저 지워야 진행 중인 STT 콜백·후처리 Task가 결과를 내보내지 못한다
        sessionToken = nil
        engine?.cancel()
        cleanup()   // 원본 오디오 파일도 여기서 지워진다
        setState(.idle)
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
            onActionNeeded?(.sttKeyMissing(providerName: STTPresets.name(for: provider)))
            setState(.idle)
            return
        }
        activeProfile = profile
        // 결과를 붙여넣을 대상 = 지금 맨 앞에 있는 앱. 이후 바뀌면 자동주입을 건너뛴다.
        startedInAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        AudioCapture.requestPermission { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard ok else {
                    self.onActionNeeded?(.microphoneDenied)
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
        let token = UUID()
        sessionToken = token

        engine.onUpdate = { [weak self] f, i in
            guard let self, self.sessionToken == token else { return }
            self.onInterim?(f + i)
        }
        engine.onError = { [weak self] err in
            guard let self = self, self.sessionToken == token else { return }
            self.cleanup()
            self.setState(.idle)
            self.onError?(KeyTester.networkMessage(err))
        }
        engine.onFinished = { [weak self] text in
            guard let self, self.sessionToken == token else { return }
            self.handleFinal(text: text, settings: settings)
        }

        let customEndpoint = settings.stt.provider == .custom ? settings.stt.customEndpoint : nil
        engine.start(apiKey: apiKey,
                     languageHints: settings.languageHints,
                     terms: settings.dictionary.hintTerms(),
                     customEndpoint: customEndpoint)
        capture.onPCM = { [weak engine] data in engine?.sendAudio(data) }
        // 받아쓰는 도중 입력 장치가 바뀌면(에어팟 분리 등) 다시 붙는다 — 안 그러면 그 뒤로 무음만 간다
        capture.deviceResolver = {
            MainActor.assumeIsolated {
                let s = SettingsStore.shared.settings
                return AudioDevices.resolve(selectedUID: s.selectedMicrophoneUID,
                                            priority: s.microphonePriority)?.deviceID
            }
        }
        capture.onReconfigured = { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self, self.sessionToken == token, !ok else { return }
                self.onNotice?(LocalizationManager.shared.text("recorder.mic.lost"))
            }
        }
        capture.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onLevel?(level) }
        }

        // 우선순위 목록에 일치하는 장치 없으면 nil → AVAudioEngine이 시스템 기본 입력 자동 사용
        // (USB 마이크 등 외부 장치가 시스템 기본값이면 자동으로 잡힘)
        let device = AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                                          priority: settings.microphonePriority)
        let recordingURL = settings.saveRecordings ? HistoryStore.shared.newRecordingURL() : nil
        activeRecordingURL = recordingURL
        do {
            try capture.start(deviceID: device?.deviceID, recordingURL: recordingURL)
            setState(.recording)
        } catch {
            engine.cancel()
            self.engine = nil
            capture.onPCM = nil
            if let recordingURL = recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            activeRecordingURL = nil
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
        let token = sessionToken
        finishTimeout = Task { @MainActor [weak self] in
            // 취소(결과 도착·세션 종료)되면 Task.sleep이 CancellationError를 던진다. `try?`로 삼키면
            // 취소됐는데도 아래로 흘러내려, 결과가 정상 도착한 직후에 가짜 '지연' 에러가 뜬다.
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self = self, self.state == .finishing, self.sessionToken == token else { return }
            self.engine?.cancel()
            self.cleanup()
            self.setState(.idle)
            self.onError?("STT 응답이 지연되어 종료했습니다. 네트워크 또는 키를 확인하세요.")
        }
    }

    private func handleFinal(text: String, settings: AppSettings) {
        // STT 결과가 도착했으니 "STT 응답 지연" 가드는 여기서 끝낸다. 안 끄면 LLM 후처리(최대 30초)가
        // 15초를 넘길 때 가짜 지연 에러가 뜨고 상태가 idle로 풀려, 그 사이 시작한 새 세션을
        // 아래 Task의 cleanup()이 죽인다.
        finishTimeout?.cancel()
        finishTimeout = nil
        let token = sessionToken
        capture.stop()
        let store = SettingsStore.shared
        let profile = activeProfile
        let raw = text
        // 소유권을 이 클로저로 넘김 — cleanup()이 뒤에 호출돼도 여기서 지운 파일을 건드리지 않음
        let recordingURL = activeRecordingURL
        activeRecordingURL = nil
        let expectedApp = startedInAppBundleID
        Task { @MainActor in
            var out = text
            var pasted = false
            // 프로파일이 LLM 사용 시에만 후처리 (번역/요약/정리 등)
            if let profile = profile, profile.useLLM {
                let outcome = await PostProcessRunner.run(transcript: out,
                                                          instruction: profile.instruction,
                                                          llm: settings.llm,
                                                          apiKey: store.llmAPIKey(for: settings.llm.endpoint),
                                                          glossary: settings.dictionary.hintTerms())
                out = outcome.text
                // 실패는 흐름을 끊지 않되 알린다 — 안 알리면 "영어 번역"이 한국어 원문을 붙여넣어도 모른다.
                if let reason = outcome.failure, !out.isEmpty, self.sessionToken == token {
                    self.onNotice?("'\(profile.name)' 후처리에 실패해 원문을 붙여넣었습니다.\n\(reason)")
                }
            }
            // 후처리 동안 세션이 취소됐으면(Esc 등) 붙여넣지 않고, 이미 시작된 다른 세션도 건드리지 않는다.
            guard self.sessionToken == token else {
                if let recordingURL = recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
                return
            }
            // 단어사전은 STT context.terms 로 인식 단계에서 이미 교정됨 (별도 후처리 불필요)
            if !out.isEmpty {
                // 결과는 항상 클립보드에 복사됨 (놓쳐도 Cmd+V 가능)
                pasted = TextInjector.injectText(out, autoPaste: settings.autoPaste,
                                                 expectedAppBundleID: expectedApp,
                                                 onSkippedDueToAppSwitch: { [weak self] in
                    Task { @MainActor in
                        self?.onNotice?("결과를 처리하는 동안 다른 앱으로 전환돼 자동 붙여넣기를 건너뛰었습니다. 클립보드에 복사돼 있습니다 — Cmd+V로 붙여넣으세요.")
                    }
                })
                // autoPaste인데 권한이 없어 못 붙인 경우 1회 안내 + 시스템 설정 유도
                if settings.autoPaste && !pasted && !TextInjector.hasAccessibility() && !Self.accessibilityWarned {
                    Self.accessibilityWarned = true
                    // 시스템이 "시스템 설정 열기" 버튼 달린 권한 창을 직접 띄운다 — 우리 쪽은 토스트로 상황만 알린다
                    TextInjector.promptAccessibility()
                    self.onNotice?("자동 붙여넣기엔 '손쉬운 사용' 권한이 필요합니다. 켠 뒤 앱을 다시 실행하세요.\n지금 결과는 클립보드에 있습니다 — Cmd+V로 붙여넣으세요.")
                }
            }
            // 히스토리 기록 (원문 + 최종본 + 원본 오디오)
            if !raw.isEmpty || !out.isEmpty {
                HistoryStore.shared.add(profileName: profile?.name ?? "받아쓰기",
                                        raw: raw,
                                        final: out,
                                        autoPasted: pasted,
                                        audioFileName: recordingURL?.lastPathComponent)
            } else if let recordingURL = recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            self.cleanup()
            self.setState(.idle)
        }
    }

    private func cleanup() {
        finishTimeout?.cancel()
        finishTimeout = nil
        sessionToken = nil
        startedInAppBundleID = nil
        capture.stop()
        capture.onPCM = nil
        capture.onLevel = nil
        engine = nil
        // 히스토리에 붙지 못한 채(에러·타임아웃) 남은 녹음 파일 정리
        if let url = activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
            activeRecordingURL = nil
        }
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }
}
