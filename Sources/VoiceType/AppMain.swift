import Foundation
import AppKit
import VoiceTypeCore

enum AppMain {
    @MainActor
    static func run() {
        let args = CommandLine.arguments

        // CLI 전사 모드 (마이크/UI 없이 STT 파이프라인 검증)
        if let idx = args.firstIndex(of: "--transcribe-file"), idx + 1 < args.count {
            CLITranscriber.run(path: args[idx + 1])
            return
        }

        // 인디케이터 헤드리스 렌더 (디스플레이 세션 없이 PNG로 픽셀 검증). --render-indicators <출력폴더>
        if let idx = args.firstIndex(of: "--render-indicators"), idx + 1 < args.count {
            let dir = args[idx + 1]
            for style in IndicatorStyle.allCases where style != .off {
                guard let img = IndicatorRenderer.image(style: style),
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("render fail: \(style.rawValue)\n".utf8))
                    continue
                }
                let path = (dir as NSString).appendingPathComponent("render_\(style.rawValue).png")
                try? png.write(to: URL(fileURLWithPath: path))
                print("\(style.rawValue): \(img.size) -> \(path)")
            }
            return
        }

        // 토스트 알림 헤드리스 렌더 (픽셀 검증). --render-toast <출력폴더>
        if let idx = args.firstIndex(of: "--render-toast"), idx + 1 < args.count {
            let written = ToastRenderer.renderAll(to: args[idx + 1])
            written.forEach { print($0) }
            exit(written.isEmpty ? 1 : 0)
        }

        // 녹음 중 입력 장치 구성 변경 복구 실측. --selftest-device-change [초] (기본 4)
        if let idx = args.firstIndex(of: "--selftest-device-change") {
            let seconds = (idx + 1 < args.count ? Double(args[idx + 1]) : nil) ?? 4
            DeviceChangeSelfTest.run(seconds: seconds)
            return
        }

        // 마이크 녹음 실측 (GUI 없이 캡처 파이프라인 검증). --record-audio [초] (기본 10)
        if let idx = args.firstIndex(of: "--record-audio") {
            let seconds = (idx + 1 < args.count ? Double(args[idx + 1]) : nil) ?? 10
            RecordAudioCLI.run(seconds: seconds)
            return
        }

        // 인디케이터 미리보기 (비주얼 검증용). --preview-indicator [스타일] (기본 waveform)
        if let idx = args.firstIndex(of: "--preview-indicator") {
            let style = (idx + 1 < args.count ? IndicatorStyle(rawValue: args[idx + 1]) : nil) ?? .waveform
            IndicatorPreview.run(style: style)
            return
        }

        // 온보딩 미리보기 (비주얼 검증용 — 완료 플래그 무시)
        if args.contains("--preview-onboarding") {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            let ob = OnboardingController()
            ob.onFinish = { NSApp.terminate(nil) }
            ob.show()
            app.run()
            return
        }

        // 메뉴바 앱
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Dock 아이콘 없는 메뉴바 전용
        app.run()
    }
}

/// Task 결과 전달용 박스 (CLI 동기 대기)
private final class ResultBox: @unchecked Sendable {
    var value: String?
}

/// 파일 → Soniox 전사 (CLI 통합 테스트용)
enum CLITranscriber {
    static func run(path: String) {
        let isDeepgram = ProcessInfo.processInfo.environment["VT_PROVIDER"] == "deepgram"
        guard let apiKey = ProcessInfo.processInfo.environment["SONIOX_API_KEY"]
                ?? Keychain.get(Keychain.sonioxKey) ?? (isDeepgram ? "" : nil) else {
            FileHandle.standardError.write(Data("SONIOX_API_KEY 환경변수 또는 Keychain 키가 없습니다\n".utf8))
            exit(2)
        }
        var settings = AppSettings.default
        settings.dictionary = TermDictionary(rawText: "Aphex Twin, Four Tet, Floating Points")

        // VT_PROVIDER=deepgram 이면 Deepgram 클라이언트로 같은 경로를 검증 (키는 환경변수 또는 Keychain)
        let client: STTEngine
        var sttKey = apiKey
        if ProcessInfo.processInfo.environment["VT_PROVIDER"] == "deepgram" {
            sttKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
                ?? Keychain.get(STTEngineFactory.keychainAccount(for: .deepgram)) ?? ""
            client = DeepgramClient()
        } else {
            client = SonioxClient()
        }
        let sem = DispatchSemaphore(value: 0)
        var resultText: String?
        let t0 = Date()
        let trace = ProcessInfo.processInfo.environment["VT_TRACE"] != nil
        func tr(_ m: String) { if trace { FileHandle.standardError.write(Data(String(format: "%5.2fs %@\n", Date().timeIntervalSince(t0), m).utf8)) } }
        client.onUpdate = { f, i in tr("update final='\(f)' interim='\(i)'") }
        client.onFinished = { text in tr("FINISHED '\(text)'"); resultText = text; sem.signal() }
        client.onError = { err in
            FileHandle.standardError.write(Data("ERROR: \(err.localizedDescription)\n".utf8))
            sem.signal()
        }
        client.start(apiKey: sttKey,
                     languageHints: settings.languageHints,
                     terms: settings.dictionary.hintTerms(),
                     customEndpoint: nil)

        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        DispatchQueue.global().async {
            let chunk = 3200 // 0.1s @ 16k s16le
            var i = 0
            while i < data.count {
                let end = min(i + chunk, data.count)
                client.sendAudio(data.subdata(in: i..<end))
                Thread.sleep(forTimeInterval: 0.1)
                i = end
            }
            tr("audio sent → finish()")
            client.finish()
        }

        let deadline = Date().addingTimeInterval(60)
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            if Date() > deadline {
                FileHandle.standardError.write(Data("TIMEOUT\n".utf8))
                exit(3)
            }
        }
        guard let t = resultText else { exit(1) }

        var out = t
        let env = ProcessInfo.processInfo.environment
        // LLM 후처리 검증 (env LLM_INSTRUCTION + LLM_API_KEY 있을 때만)
        if let inst = env["LLM_INSTRUCTION"], !inst.isEmpty,
           let lkey = env["LLM_API_KEY"] ?? (LLMPresets.isCodexCLI(env["LLM_ENDPOINT"] ?? "") ? "" : nil) {
            let cfg = LLMConfig(endpoint: env["LLM_ENDPOINT"] ?? "https://api.openai.com/v1/chat/completions",
                                model: env["LLM_MODEL"] ?? "gpt-4o-mini")
            let sem2 = DispatchSemaphore(value: 0)
            let box = ResultBox()
            let input = out
            Task {
                let r = await PostProcessRunner.run(transcript: input, instruction: inst,
                                                    llm: cfg, apiKey: lkey,
                                                    glossary: settings.dictionary.hintTerms())
                box.value = r.text
                if let f = r.failure { FileHandle.standardError.write(Data("LLM 후처리 실패: \(f)\n".utf8)) }
                sem2.signal()
            }
            while sem2.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            out = box.value ?? out
        }
        print("TRANSCRIPT: \(out)")
        exit(0)
    }
}
