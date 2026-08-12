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

/// LLM 프로바이더별 Keychain 슬롯 라우팅 (council 반영: normalize + Custom 해시 분리)
final class LLMKeychainAccountTests: XCTestCase {
    func testKnownProviderGetsStableSlot() {
        let ep = "https://api.openai.com/v1/chat/completions"
        XCTAssertEqual(LLMPresets.keychainAccount(endpoint: ep), "llm_api_key.OpenAI")
    }

    func testTrailingSlashAndCaseStillMatchKnownProvider() {
        // 표기 흔들려도 Custom으로 새지 않고 같은 프로바이더 슬롯으로 라우팅
        let a = LLMPresets.keychainAccount(endpoint: "https://api.openai.com/v1/chat/completions")
        let b = LLMPresets.keychainAccount(endpoint: "https://api.openai.com/v1/chat/completions/")
        let c = LLMPresets.keychainAccount(endpoint: "  HTTPS://API.OpenAI.com/v1/chat/completions  ")
        XCTAssertEqual(a, "llm_api_key.OpenAI")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testDifferentProvidersGetDifferentSlots() {
        let openai = LLMPresets.keychainAccount(endpoint: "https://api.openai.com/v1/chat/completions")
        let deepseek = LLMPresets.keychainAccount(endpoint: "https://api.deepseek.com/v1/chat/completions")
        XCTAssertNotEqual(openai, deepseek)
        XCTAssertEqual(deepseek, "llm_api_key.DeepSeek")
    }

    func testDistinctCustomEndpointsDoNotCollide() {
        // council HIGH 지적: 여러 커스텀 endpoint가 단일 Custom 슬롯 공유하던 문제 해결 확인
        let x = LLMPresets.keychainAccount(endpoint: "https://api.foo.example/v1/chat/completions")
        let y = LLMPresets.keychainAccount(endpoint: "https://api.bar.example/v1/chat/completions")
        XCTAssertNotEqual(x, y)
        XCTAssertTrue(x.hasPrefix("llm_api_key.custom_"))
        XCTAssertTrue(y.hasPrefix("llm_api_key.custom_"))
    }

    func testSameCustomEndpointStableAcrossFormatting() {
        let x = LLMPresets.keychainAccount(endpoint: "https://api.foo.example/v1/chat/completions")
        let y = LLMPresets.keychainAccount(endpoint: "https://api.foo.example/v1/chat/completions/")
        XCTAssertEqual(x, y)
    }
}

// MARK: - F5 녹음기

final class RecordingIDTests: XCTestCase {
    private let kst = TimeZone(identifier: "Asia/Seoul")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kst
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)!
    }

    func testFormatIsYYMMDDHHMMSSWithSuffix() {
        XCTAssertEqual(RecordingID.make(from: date(2026, 8, 13, 14, 30, 5),
                                        random: "a1b2", timeZone: kst),
                       "260813_143005_a1b2")
    }

    func testSameMinuteDifferentSecondsDoNotCollide() {
        let a = RecordingID.make(from: date(2026, 8, 13, 14, 30, 5), random: "aaaa", timeZone: kst)
        let b = RecordingID.make(from: date(2026, 8, 13, 14, 30, 6), random: "aaaa", timeZone: kst)
        XCTAssertNotEqual(a, b)
    }

    func testRandomSuffixIsFourLowercaseHexChars() {
        for _ in 0..<50 {
            let s = RecordingID.randomSuffix()
            XCTAssertEqual(s.count, 4)
            XCTAssertTrue(s.allSatisfy { "0123456789abcdef".contains($0) }, "잘못된 문자: \(s)")
        }
    }
}

final class RecordingSessionTests: XCTestCase {
    private func sample() -> RecordingSession {
        RecordingSession(
            id: "260813_143005_a1b2",
            startedAt: Date(timeIntervalSince1970: 1_786_000_000),
            durationSeconds: 4331.2,
            captureStatus: .done,
            tracks: [
                TrackInfo(kind: .mic, fileName: "mic.m4a", durationSeconds: 4331.2),
                TrackInfo(kind: .system, fileName: "system.m4a", durationSeconds: 4330.9,
                          discontinuities: [DiscontinuityRecord(fileTime: 1200.0, wallTime: 1203.5,
                                                                gapSeconds: 3.5, reason: "capture_gap")]),
            ],
            transcriptionStatus: .pending)
    }

    func testRoundTripEncodeDecode() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RecordingSession.self, from: data), original)
    }

    func testTrackLookup() {
        let s = sample()
        XCTAssertEqual(s.track(.mic)?.fileName, "mic.m4a")
        XCTAssertEqual(s.track(.system)?.discontinuities.count, 1)
    }

    /// 시스템 트랙이 없는 세션(맥북만 들고 녹음)도 정상이어야 한다.
    func testMicOnlySessionHasNoSystemTrack() {
        var s = sample()
        s.tracks = s.tracks.filter { $0.kind == .mic }
        XCTAssertNil(s.track(.system))
        XCTAssertNotNil(s.track(.mic))
    }

    func testLenientDecodingOfMinimalJSON() throws {
        let json = #"{"id":"260813_143005_a1b2","startedAt":709171200}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RecordingSession.self, from: json)
        XCTAssertEqual(s.id, "260813_143005_a1b2")
        XCTAssertEqual(s.durationSeconds, 0)
        XCTAssertEqual(s.captureStatus, .failed)
        XCTAssertTrue(s.tracks.isEmpty)
        XCTAssertEqual(s.transcriptionStatus, .pending)
    }

    /// 알 수 없는 status 문자열은 안전한 기본값으로 떨어져야 한다.
    func testUnknownStatusFallsBack() throws {
        let json = #"{"id":"x","startedAt":0,"captureStatus":"weird","transcriptionStatus":"weird"}"#
            .data(using: .utf8)!
        let s = try JSONDecoder().decode(RecordingSession.self, from: json)
        XCTAssertEqual(s.captureStatus, .failed)
        XCTAssertEqual(s.transcriptionStatus, .pending)
    }

    func testNeedsRecoveryWhenCaptureNotDone() {
        var s = sample()
        s.captureStatus = .recording
        XCTAssertTrue(s.needsRecovery)
        s.captureStatus = .done
        XCTAssertFalse(s.needsRecovery)
    }
}

final class TrackClockTests: XCTestCase {
    /// 16kHz에서 1600프레임 = 0.1초
    func testAdvanceAccumulatesWrittenSeconds() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 1600)
        XCTAssertEqual(c.writtenSeconds, 0.1, accuracy: 1e-9)
        c.advance(frameCount: 1600)
        XCTAssertEqual(c.writtenSeconds, 0.2, accuracy: 1e-9)
    }

    func testNoSilenceWhenWithinThreshold() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)
        XCTAssertNil(c.silenceNeeded(atWallTime: 1.05))
    }

    func testSilenceInsertedWhenGapExceedsThreshold() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)
        let gap = c.silenceNeeded(atWallTime: 4.5)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap!, 3.5, accuracy: 1e-9)
        XCTAssertEqual(c.writtenSeconds, 4.5, accuracy: 1e-9)
        XCTAssertNil(c.silenceNeeded(atWallTime: 4.5), "이미 메운 공백을 또 요구하면 안 된다")
    }

    /// 버퍼가 앞서 도착하면(벽시계가 기록량보다 뒤) 무음을 넣지 않는다.
    func testNoSilenceWhenWallTimeBehind() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)
        XCTAssertNil(c.silenceNeeded(atWallTime: 0.5))
        XCTAssertEqual(c.writtenSeconds, 1.0, accuracy: 1e-9)
    }

    func testRecordGapProducesDiscontinuityAtPreGapFileTime() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)
        let gap = c.silenceNeeded(atWallTime: 4.5)!
        let rec = c.recordGap(wallTime: 4.5, gapSeconds: gap, reason: "capture_gap")
        XCTAssertEqual(rec.fileTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rec.wallTime, 4.5, accuracy: 1e-9)
        XCTAssertEqual(rec.gapSeconds, 3.5, accuracy: 1e-9)
        XCTAssertEqual(rec.reason, "capture_gap")
    }
}

final class RecordingSettingsTests: XCTestCase {
    /// 기존 settings.json에는 녹음 필드가 없다. 기본값이 채워지고 기존 값은 살아남아야 한다.
    func testLegacySettingsGainRecordingDefaults() throws {
        let json = """
        {"autoPaste":true,"profiles":[{"id":"\(UUID().uuidString)","name":"받아쓰기",
        "hotkeyKeyCode":100,"hotkeyModifiers":0,"useLLM":true,"instruction":"x",
        "triggerMode":"toggle"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.recordingHotkeyKeyCode, 96, "F5")
        XCTAssertEqual(s.recordingHotkeyModifiers, 0)
        XCTAssertEqual(s.recordingFolderPath, "")
        XCTAssertEqual(s.profiles.count, 1)
        XCTAssertEqual(s.profiles.first?.name, "받아쓰기")
    }

    func testRecordingSettingsRoundTrip() throws {
        var s = AppSettings()
        s.recordingHotkeyKeyCode = 97
        s.recordingFolderPath = "/tmp/rec"
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.recordingHotkeyKeyCode, 97)
        XCTAssertEqual(back.recordingFolderPath, "/tmp/rec")
    }
}
