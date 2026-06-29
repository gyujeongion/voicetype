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

        // 인디케이터 미리보기 (비주얼 검증용)
        if args.contains("--preview-indicator") {
            IndicatorPreview.run()
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
        guard let apiKey = ProcessInfo.processInfo.environment["SONIOX_API_KEY"]
                ?? Keychain.get(Keychain.sonioxKey) else {
            FileHandle.standardError.write(Data("SONIOX_API_KEY 환경변수 또는 Keychain 키가 없습니다\n".utf8))
            exit(2)
        }
        var settings = AppSettings.default
        settings.dictionary = TermDictionary(rawText: "Aphex Twin, Four Tet, Floating Points")

        let client = SonioxClient()
        let sem = DispatchSemaphore(value: 0)
        var resultText: String?
        client.onFinished = { text in resultText = text; sem.signal() }
        client.onError = { err in
            FileHandle.standardError.write(Data("ERROR: \(err.localizedDescription)\n".utf8))
            sem.signal()
        }
        client.start(apiKey: apiKey,
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
        if let inst = env["LLM_INSTRUCTION"], !inst.isEmpty, let lkey = env["LLM_API_KEY"] {
            let cfg = LLMConfig(endpoint: env["LLM_ENDPOINT"] ?? "https://api.openai.com/v1/chat/completions",
                                model: env["LLM_MODEL"] ?? "gpt-4o-mini")
            let sem2 = DispatchSemaphore(value: 0)
            let box = ResultBox()
            let input = out
            Task {
                let r = await PostProcessRunner.run(transcript: input, instruction: inst,
                                                    llm: cfg, apiKey: lkey,
                                                    glossary: settings.dictionary.hintTerms())
                box.value = r
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
