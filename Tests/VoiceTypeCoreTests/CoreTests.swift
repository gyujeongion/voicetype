import XCTest
@testable import VoiceTypeCore

final class TranscriptAssemblerTests: XCTestCase {
    func testFinalAndInterimAccumulation() {
        let a = TranscriptAssembler()
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: "안녕", isFinal: false)]))
        XCTAssertEqual(a.finalText, "")
        XCTAssertEqual(a.interimText, "안녕")
        let changed = a.ingest(Soniox.Response(tokens: [
            Soniox.Token(text: "안녕", isFinal: true),
            Soniox.Token(text: "하세요", isFinal: true),
        ]))
        XCTAssertTrue(changed)
        XCTAssertEqual(a.finalText, "안녕하세요")
        XCTAssertEqual(a.interimText, "")
    }

    func testResultTrimming() {
        let a = TranscriptAssembler()
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: "  테스트  ", isFinal: true)]))
        XCTAssertEqual(a.result(), "테스트")
    }

    func testFinishedMessageNoTokens() {
        let a = TranscriptAssembler()
        let changed = a.ingest(Soniox.Response(tokens: [], finished: true))
        XCTAssertFalse(changed)
        XCTAssertTrue(a.isFinished)
    }

    func testEndTokenIsExcludedAndSignalsFinish() {
        let a = TranscriptAssembler()
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: "테스트", isFinal: true)]))
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: Soniox.endToken, isFinal: true)]))
        XCTAssertEqual(a.result(), "테스트")
        XCTAssertTrue(a.isFinished)
    }

    /// endpoint detection의 <end> 토큰은 출력에서 제외하되 스트림은 계속돼야 한다.
    func testSegmentEndTokenIsStrippedButStreamContinues() {
        let a = TranscriptAssembler()
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: "가격은 얼마야?", isFinal: true)]))
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: Soniox.segmentEndToken, isFinal: true)]))
        // <end> 후에도 계속 받아씀
        _ = a.ingest(Soniox.Response(tokens: [Soniox.Token(text: " 유명한 업체는?", isFinal: true)]))
        XCTAssertEqual(a.result(), "가격은 얼마야? 유명한 업체는?")
        XCTAssertFalse(a.isFinished)   // <end>는 종료 신호가 아님
    }
}

final class TermDictionaryTests: XCTestCase {
    func testCommaSeparated() {
        let dict = TermDictionary(rawText: "Aphex Twin, Four Tet, Floating Points")
        XCTAssertEqual(dict.hintTerms(), ["Aphex Twin", "Four Tet", "Floating Points"])
    }

    func testNewlineAndMixedSeparators() {
        let dict = TermDictionary(rawText: "Aphex Twin\nFour Tet,  Burial ; Actress\n")
        XCTAssertEqual(dict.hintTerms(), ["Aphex Twin", "Four Tet", "Burial", "Actress"])
    }

    func testEmptyDictionary() {
        XCTAssertEqual(TermDictionary().hintTerms(), [])
    }

    func testParenthesesSplitToBothTerms() {
        let dict = TermDictionary(rawText: "포 텟 (Four Tet)\n플로팅 포인츠 (Floating Points)\n에이펙스 트윈 (Aphex Twin)")
        XCTAssertEqual(dict.hintTerms(), ["Four Tet", "포 텟", "Floating Points", "플로팅 포인츠", "Aphex Twin", "에이펙스 트윈"])
    }

    func testMultiwordTermPreserved() {
        let dict = TermDictionary(rawText: "Four Tet\nFloating Points")
        XCTAssertEqual(dict.hintTerms(), ["Four Tet", "Floating Points"])
    }

    func testDeduplication() {
        let dict = TermDictionary(rawText: "에이펙스 트윈 (Aphex Twin)\nAphex Twin\n에이펙스 트윈")
        XCTAssertEqual(dict.hintTerms(), ["Aphex Twin", "에이펙스 트윈"])
    }
}

final class SonioxProtocolTests: XCTestCase {
    func testStartConfigEncoding() throws {
        let cfg = Soniox.StartConfig(apiKey: "KEY",
                                     languageHints: ["ko", "en"],
                                     context: .init(terms: ["Four Tet", "Floating Points"]))
        let data = try cfg.jsonData()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["api_key"] as? String, "KEY")
        XCTAssertEqual(obj["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(obj["audio_format"] as? String, "s16le")
        XCTAssertEqual(obj["sample_rate"] as? Int, 16000)
        XCTAssertEqual(obj["num_channels"] as? Int, 1)
        XCTAssertEqual(obj["enable_endpoint_detection"] as? Bool, true)
        let ctx = obj["context"] as? [String: Any]
        XCTAssertEqual(ctx?["terms"] as? [String], ["Four Tet", "Floating Points"])
    }

    func testResponseDecoding() throws {
        let json = """
        {"tokens":[{"text":"안녕","is_final":true,"confidence":0.97,"language":"ko"}],"total_audio_proc_ms":880}
        """.data(using: .utf8)!
        let resp = try Soniox.decode(json)
        XCTAssertEqual(resp.tokens?.count, 1)
        XCTAssertEqual(resp.tokens?.first?.text, "안녕")
        XCTAssertEqual(resp.tokens?.first?.isFinal, true)
    }

    func testFinishedDecoding() throws {
        let json = #"{"tokens":[],"finished":true}"#.data(using: .utf8)!
        let resp = try Soniox.decode(json)
        XCTAssertEqual(resp.finished, true)
    }
}

final class PromptBuilderTests: XCTestCase {
    func testRequestBodyShape() throws {
        let cfg = LLMConfig(model: "gpt-4o-mini")
        let body = PromptBuilder.requestBody(transcript: "테스트 문장",
                                             instruction: "영어로 번역",
                                             glossary: ["Four Tet"],
                                             config: cfg)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        let messages = body["messages"] as! [[String: Any]]
        // system + few-shot user + few-shot assistant + actual transcript = 4
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1]["role"] as? String, "user")       // few-shot user
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")  // few-shot assistant
        XCTAssertEqual(messages[3]["content"] as? String, "<transcript>테스트 문장</transcript>")
        let sys = messages[0]["content"] as! String
        XCTAssertTrue(sys.contains("Four Tet"))
        XCTAssertTrue(sys.contains("영어로 번역"))
    }

    func testTranslationFewShotIsEnglish() {
        // 번역 지시 → few-shot 예시 출력이 영어여야 cleanup 예시 오염을 막음
        let body = PromptBuilder.requestBody(transcript: "안녕",
                                             instruction: "한국어를 영어로 번역",
                                             glossary: [], config: LLMConfig())
        let messages = body["messages"] as! [[String: Any]]
        let fewShotAssistant = messages[2]["content"] as! String
        XCTAssertTrue(fewShotAssistant.lowercased().contains("residential proxies"))
        XCTAssertFalse(fewShotAssistant.contains("레지던셜"))
    }

    func testCleanupFewShotIsKorean() {
        let body = PromptBuilder.requestBody(transcript: "안녕",
                                             instruction: "맞춤법만 교정",
                                             glossary: [], config: LLMConfig())
        let messages = body["messages"] as! [[String: Any]]
        let fewShotAssistant = messages[2]["content"] as! String
        XCTAssertTrue(fewShotAssistant.contains("레지던셜"))
    }

    func testLooksLikeTranslation() {
        XCTAssertTrue(PromptBuilder.looksLikeTranslation("영어로 번역해줘"))
        XCTAssertTrue(PromptBuilder.looksLikeTranslation("translate to English"))
        XCTAssertTrue(PromptBuilder.looksLikeTranslation("일본어로 바꿔"))
        XCTAssertFalse(PromptBuilder.looksLikeTranslation("맞춤법만 다듬어"))
        XCTAssertFalse(PromptBuilder.looksLikeTranslation("3줄로 요약"))
    }

    func testEmptyInstructionFallsBackToCleanup() {
        let sys = PromptBuilder.systemPrompt(instruction: "", glossary: [])
        XCTAssertTrue(sys.contains("맞춤법"))
    }

    func testExtractContent() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"  정리된 문장  "}}]}"#.data(using: .utf8)!
        XCTAssertEqual(PromptBuilder.extractContent(json), "정리된 문장")
    }
}

final class LLMPresetTests: XCTestCase {
    func testPresetMatch() {
        let p = LLMPresets.match(endpoint: "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(p.name, "DeepSeek")
    }
    func testUnknownEndpointFallsBackToCustom() {
        let p = LLMPresets.match(endpoint: "https://my.local/v1/chat/completions")
        XCTAssertTrue(p.isCustom)
    }
    func testDefaultLLMIsDeepSeekChat() {
        XCTAssertEqual(LLMConfig().model, "deepseek-chat")
        XCTAssertTrue(LLMConfig().endpoint.contains("deepseek"))
    }
    func testOllamaDoesNotRequireAPIKey() {
        let p = LLMPresets.match(endpoint: "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(p.name, "Ollama")
        XCTAssertFalse(p.requiresAPIKey)
        XCTAssertTrue(LLMPresets.isLocalEndpoint(p.endpoint))
    }
}

final class AppSettingsTests: XCTestCase {
    func testDefaultProfilesSeed() {
        let s = AppSettings.default
        XCTAssertEqual(s.profiles.count, 2)
        XCTAssertEqual(s.profiles[0].name, "Dictation")
        XCTAssertEqual(s.profiles[0].hotkeyKeyCode, 49)   // kVK_Space
        XCTAssertEqual(s.profiles[0].hotkeyModifiers, 2048) // optionKey
        XCTAssertTrue(s.profiles[0].useLLM)
        XCTAssertEqual(s.profiles[1].name, "Translate to English")
        XCTAssertEqual(s.profiles[1].hotkeyKeyCode, 49)
        XCTAssertTrue(s.profiles[1].useLLM)
    }

    func testRoundTrip() throws {
        var s = AppSettings.default
        s.dictionary = TermDictionary(rawText: "Four Tet, Floating Points")
        s.profiles.append(PromptProfile(name: "Summary", hotkeyKeyCode: 97, useLLM: true, instruction: "Summarise in 3 lines"))
        let data = try s.encoded()
        let back = AppSettings.decoded(from: data)
        XCTAssertEqual(back?.dictionary.hintTerms(), ["Four Tet", "Floating Points"])
        XCTAssertEqual(back?.profiles.count, 3)
        XCTAssertEqual(back?.profiles.last?.instruction, "Summarise in 3 lines")
    }

    func testLenientDecodingPreservesProfiles() {
        let json = """
        {"profiles":[{"id":"\(UUID().uuidString)","name":"내커스텀","hotkeyKeyCode":99,"useLLM":true,"instruction":"내 지시"}],
         "futureUnknownField":123}
        """.data(using: .utf8)!
        let s = AppSettings.decoded(from: json)
        XCTAssertEqual(s?.profiles.first?.name, "내커스텀")
        XCTAssertEqual(s?.profiles.first?.instruction, "내 지시")
        XCTAssertEqual(s?.autoPaste, true)
    }

}
