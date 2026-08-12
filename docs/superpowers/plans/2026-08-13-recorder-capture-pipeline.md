# VoiceType F5 녹음기 — 캡처 파이프라인 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** F5 키로 마이크와 시스템 오디오를 각각 별도 트랙으로 녹음하고, 크래시에도 살아남는 파일로 저장한다.

**Architecture:** 2레이어 캡처. 마이크는 기존 `AudioCapture`(AVAudioEngine)를 확장해 항상 즉시 시작하고, 시스템 오디오는 `SCStream`(`capturesAudio`, macOS 13+)으로 선택적으로 얹는다. 두 트랙 모두 녹음 중에는 LPCM CAF로 기록하고(헤더 확정 불필요 → 크래시 내성), 정상 종료 시 m4a로 트랜스코딩한다. 순수 로직은 전부 `VoiceTypeCore`에 두어 캡처·네트워크 없이 테스트한다.

**Tech Stack:** Swift 6.0 / SwiftPM / XCTest / AVFoundation / ScreenCaptureKit / CoreAudio / IOKit.pwr_mgt

**범위 밖 (다음 계획):** STT 배치 전사, 전사문 병합, 누설 중복 제거, 마크다운 렌더, 설정 UI. 이 계획이 끝나면 녹음 파일은 남지만 `transcript.md`는 생성되지 않는다. 남은 m4a는 `/stt` 스킬로 수동 전사할 수 있으므로 그 자체로 쓸모 있는 상태다.

**스펙:** `docs/superpowers/specs/2026-08-12-meeting-recorder-design.md`

## Global Constraints

- 배포 타겟 **macOS 14** 유지. `SCStreamOutputTypeMicrophone`·`captureMicrophone`·`microphoneCaptureDeviceID`(전부 macOS 15+)를 **쓰지 않는다.** 시스템 오디오는 `capturesAudio`(macOS 13+)만 사용한다.
- 테스트 프레임워크는 **XCTest**. 기존 `Tests/VoiceTypeCoreTests/CoreTests.swift` 규약을 따른다(`final class XxxTests: XCTestCase`, `func testCamelCase`).
- `VoiceTypeCore`에는 **시스템 API 의존을 넣지 않는다.** `Foundation`만 import한다. AVFoundation·ScreenCaptureKit·AppKit이 필요하면 `Sources/VoiceType`에 둔다.
- 코어 모델은 `public struct`/`public enum` + `Codable, Sendable`. 문서 주석은 한국어 `///`.
- `Codable` 모델은 **관대한 디코딩** 필수 — 커스텀 `init(from:)` + `CodingKeys`, 누락 필드는 `(try? c.decode(...)) ?? 기본값`. 기존 `AppSettings.swift:139-160` 패턴을 그대로 따른다.
- 녹음 파일은 **절대 자동 삭제하지 않는다.** 기존 히스토리의 300건 cap·30일 만료 로직을 녹음에 적용하지 않는다.
- 녹음 중 파일 쓰기는 **캡처 콜백에서 하지 않는다.** 전용 직렬 `DispatchQueue`로 넘긴다.
- 시스템 오디오 실패는 **녹음 실패가 아니다.** 마이크 트랙은 어떤 경우에도 계속된다.
- 커밋 메시지는 기존 규약대로 `feat:`/`fix:`/`test:` 접두사 + 한국어 본문.

## File Structure

**신규 — `Sources/VoiceTypeCore/` (순수 로직, 테스트 대상)**

| 파일 | 책임 |
|---|---|
| `RecordingSession.swift` | 회차 메타데이터 모델 + 관대한 디코딩 |
| `RecordingID.swift` | 폴더 ID 생성 (순수 함수) |
| `TrackClock.swift` | 벽시계 대비 기록량 추적, 무음 삽입량 산출 |

**신규 — `Sources/VoiceType/` (시스템 의존)**

| 파일 | 책임 |
|---|---|
| `RecordingStore.swift` | 회차 폴더 생성, manifest 원자적 입출력, 미완료 스캔 |
| `CAFWriter.swift` | LPCM CAF 기록 + 무음 삽입, 직렬 큐 |
| `AudioTranscoder.swift` | CAF → 16kHz mono AAC m4a 변환 |
| `MicTrackRecorder.swift` | AVAudioEngine 마이크 → CAF |
| `SystemTrackRecorder.swift` | SCStream 시스템 오디오 → CAF |
| `PowerAssertion.swift` | IOPMAssertion 획득·해제 |
| `RecorderController.swift` | 상태 머신, 두 레이어 조율, 디스크 감시, 복구 |

**수정**

| 파일 | 변경 |
|---|---|
| `Sources/VoiceType/AudioCapture.swift` | 원시 PCM 콜백에 프레임 수·호스트시각 전달 |
| `Sources/VoiceType/AppMain.swift` | `--record-audio <초>` CLI 검증 모드 |
| `Sources/VoiceType/AppDelegate.swift` | F5 핫키(예약 id 9000), 아이콘, 받아쓰기 차단 |
| `Sources/VoiceType/DictationController.swift` | 녹음 중 `trigger()` 차단 |
| `Sources/VoiceTypeCore/AppSettings.swift` | 녹음 관련 설정 필드 추가 |
| `Info.plist` | `NSScreenCaptureUsageDescription` |
| `Tests/VoiceTypeCoreTests/CoreTests.swift` | 신규 테스트 클래스 추가 |

---

### Task 1: 회차 ID 생성

**Files:**
- Create: `Sources/VoiceTypeCore/RecordingID.swift`
- Test: `Tests/VoiceTypeCoreTests/CoreTests.swift` (파일 끝에 클래스 추가)

**Interfaces:**
- Consumes: 없음
- Produces: `RecordingID.make(from: Date, random: String, timeZone: TimeZone) -> String`, `RecordingID.randomSuffix() -> String`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/VoiceTypeCoreTests/CoreTests.swift` 끝에 추가:

```swift
final class RecordingIDTests: XCTestCase {
    private let kst = TimeZone(identifier: "Asia/Seoul")!

    func testFormatIsYYMMDDHHMMSSWithSuffix() {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 13
        c.hour = 14; c.minute = 30; c.second = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kst
        let date = cal.date(from: c)!
        XCTAssertEqual(RecordingID.make(from: date, random: "a1b2", timeZone: kst),
                       "260813_143005_a1b2")
    }

    func testSameMinuteDifferentSecondsDoNotCollide() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kst
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 13; c.hour = 14; c.minute = 30
        c.second = 5
        let a = RecordingID.make(from: cal.date(from: c)!, random: "aaaa", timeZone: kst)
        c.second = 6
        let b = RecordingID.make(from: cal.date(from: c)!, random: "aaaa", timeZone: kst)
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
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter RecordingIDTests`
Expected: 컴파일 실패 — `cannot find 'RecordingID' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Sources/VoiceTypeCore/RecordingID.swift` 신규:

```swift
import Foundation

/// 녹음 회차 폴더 이름 생성. 형식 `YYMMDD_HHMMSS_<4자리 hex>`.
/// 분 단위로는 충돌 가능성이 있어 초와 랜덤 접미사를 함께 쓴다. 현지화하지 않는다.
public enum RecordingID {
    /// 회차 ID를 만든다. `random`은 테스트에서 고정값을 주입하기 위해 파라미터로 받는다.
    public static func make(from date: Date,
                            random: String,
                            timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return "\(f.string(from: date))_\(random)"
    }

    /// 4자리 소문자 16진 접미사.
    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter RecordingIDTests`
Expected: 3 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceTypeCore/RecordingID.swift Tests/VoiceTypeCoreTests/CoreTests.swift
git commit -m "feat(recorder): 녹음 회차 ID 생성기 추가

YYMMDD_HHMMSS_<hex4> 형식. 초·랜덤 접미사로 동시 시작 충돌 방지."
```

---

### Task 2: 회차 메타데이터 모델

**Files:**
- Create: `Sources/VoiceTypeCore/RecordingSession.swift`
- Test: `Tests/VoiceTypeCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum TrackKind: String { case mic, system }`
  - `struct DiscontinuityRecord { fileTime: Double, wallTime: Double, gapSeconds: Double, reason: String }`
  - `struct TrackInfo { kind: TrackKind, fileName: String, durationSeconds: Double, discontinuities: [DiscontinuityRecord] }`
  - `enum CaptureStatus: String { case recording, done, failed }`
  - `enum TranscriptionStatus: String { case pending, running, done, failed, skipped }`
  - `struct RecordingSession { id, startedAt, durationSeconds, captureStatus, tracks, transcriptionStatus, transcriptionEngine, transcriptionError }`
  - `RecordingSession.track(_ kind: TrackKind) -> TrackInfo?`
  - `RecordingSession.needsRecovery: Bool`

> **스펙과의 차이:** 스펙 3.2절이 별도 타입으로 적은 `TimelineMap`은 만들지 않는다. 불연속 기록은 `TrackInfo.discontinuities` 배열로 충분하며, 별도 타입은 값을 더하지 않는다(YAGNI).

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
final class RecordingSessionTests: XCTestCase {
    private func sample() -> RecordingSession {
        RecordingSession(
            id: "260813_143005_a1b2",
            startedAt: Date(timeIntervalSince1970: 1_786_000_000),
            durationSeconds: 4331.2,
            captureStatus: .done,
            tracks: [
                TrackInfo(kind: .mic, fileName: "mic.m4a", durationSeconds: 4331.2, discontinuities: []),
                TrackInfo(kind: .system, fileName: "system.m4a", durationSeconds: 4330.9,
                          discontinuities: [DiscontinuityRecord(fileTime: 1200.0, wallTime: 1203.5,
                                                                gapSeconds: 3.5, reason: "sleep_gap")]),
            ],
            transcriptionStatus: .pending
        )
    }

    func testRoundTripEncodeDecode() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTrackLookup() {
        let s = sample()
        XCTAssertEqual(s.track(.mic)?.fileName, "mic.m4a")
        XCTAssertEqual(s.track(.system)?.discontinuities.count, 1)
    }

    /// 시스템 트랙이 없는 세션(시나리오 A)도 정상이어야 한다.
    func testMicOnlySessionHasNoSystemTrack() {
        var s = sample()
        s.tracks = s.tracks.filter { $0.kind == .mic }
        XCTAssertNil(s.track(.system))
        XCTAssertNotNil(s.track(.mic))
    }

    /// 구버전·필드 누락 JSON을 관대하게 읽어야 한다.
    func testLenientDecodingOfMinimalJSON() throws {
        let json = """
        {"id":"260813_143005_a1b2","startedAt":709171200}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RecordingSession.self, from: json)
        XCTAssertEqual(s.id, "260813_143005_a1b2")
        XCTAssertEqual(s.durationSeconds, 0)
        XCTAssertEqual(s.captureStatus, .failed)
        XCTAssertTrue(s.tracks.isEmpty)
        XCTAssertEqual(s.transcriptionStatus, .pending)
    }

    /// 알 수 없는 status 문자열은 안전한 기본값으로 떨어져야 한다.
    func testUnknownStatusFallsBack() throws {
        let json = """
        {"id":"x","startedAt":0,"captureStatus":"weird","transcriptionStatus":"weird"}
        """.data(using: .utf8)!
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
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter RecordingSessionTests`
Expected: 컴파일 실패 — `cannot find 'RecordingSession' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Sources/VoiceTypeCore/RecordingSession.swift` 신규:

```swift
import Foundation

/// 녹음 트랙 종류.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case mic
    case system
}

/// 캡처 중 발생한 시간 불연속 1건. 슬립·드롭아웃으로 생긴 공백을 진단하기 위해 남긴다.
public struct DiscontinuityRecord: Codable, Sendable, Equatable {
    /// 파일 내 시각(초)
    public let fileTime: Double
    /// 세션 시작 기준 실제 경과 시각(초)
    public let wallTime: Double
    /// 이 지점에 삽입한 무음 길이(초)
    public let gapSeconds: Double
    /// 원인 태그 (예: sleep_gap, device_change, queue_drop)
    public let reason: String

    public init(fileTime: Double, wallTime: Double, gapSeconds: Double, reason: String) {
        self.fileTime = fileTime
        self.wallTime = wallTime
        self.gapSeconds = gapSeconds
        self.reason = reason
    }
}

/// 트랙 1개의 기록 결과.
public struct TrackInfo: Codable, Sendable, Equatable {
    public let kind: TrackKind
    public var fileName: String
    public var durationSeconds: Double
    public var discontinuities: [DiscontinuityRecord]

    public init(kind: TrackKind,
                fileName: String,
                durationSeconds: Double = 0,
                discontinuities: [DiscontinuityRecord] = []) {
        self.kind = kind
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.discontinuities = discontinuities
    }
}

/// 캡처 진행 상태. 전사 상태와 분리한다 — 캡처는 끝났지만 전사가 실패한 상태를 표현해야 한다.
public enum CaptureStatus: String, Codable, Sendable {
    case recording
    case done
    case failed
}

/// 전사 진행 상태.
public enum TranscriptionStatus: String, Codable, Sendable {
    case pending
    case running
    case done
    case failed
    /// 사용자가 전사를 원치 않거나 트랙이 비어 건너뛴 경우
    case skipped
}

/// 녹음 회차 1건의 메타데이터. 회차 폴더의 session.json에 저장된다.
public struct RecordingSession: Codable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public var durationSeconds: Double
    public var captureStatus: CaptureStatus
    public var tracks: [TrackInfo]
    public var transcriptionStatus: TranscriptionStatus
    public var transcriptionEngine: String?
    public var transcriptionError: String?

    public init(id: String,
                startedAt: Date,
                durationSeconds: Double = 0,
                captureStatus: CaptureStatus = .recording,
                tracks: [TrackInfo] = [],
                transcriptionStatus: TranscriptionStatus = .pending,
                transcriptionEngine: String? = nil,
                transcriptionError: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.captureStatus = captureStatus
        self.tracks = tracks
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionEngine = transcriptionEngine
        self.transcriptionError = transcriptionError
    }

    enum CodingKeys: String, CodingKey {
        case id, startedAt, durationSeconds, captureStatus, tracks
        case transcriptionStatus, transcriptionEngine, transcriptionError
    }

    /// 관대한 디코딩 — 필드가 빠지거나 알 수 없는 status 문자열이어도 안전한 기본값으로 읽는다.
    /// 중단된 세션의 manifest는 필드가 덜 쓰인 상태일 수 있다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
        // 상태를 못 읽으면 .failed — 완료로 오인해 복구 대상에서 빠지는 것이 더 나쁘다
        captureStatus = (try? c.decode(CaptureStatus.self, forKey: .captureStatus)) ?? .failed
        tracks = (try? c.decode([TrackInfo].self, forKey: .tracks)) ?? []
        transcriptionStatus = (try? c.decode(TranscriptionStatus.self, forKey: .transcriptionStatus)) ?? .pending
        transcriptionEngine = try? c.decode(String.self, forKey: .transcriptionEngine)
        transcriptionError = try? c.decode(String.self, forKey: .transcriptionError)
    }

    /// 종류로 트랙을 찾는다. 시스템 트랙은 없을 수 있다.
    public func track(_ kind: TrackKind) -> TrackInfo? {
        tracks.first { $0.kind == kind }
    }

    /// 캡처가 정상 종료되지 않은 세션 — 다음 실행 시 복구 제안 대상.
    public var needsRecovery: Bool {
        captureStatus != .done
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter RecordingSessionTests`
Expected: 6 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceTypeCore/RecordingSession.swift Tests/VoiceTypeCoreTests/CoreTests.swift
git commit -m "feat(recorder): 회차 메타데이터 모델 추가

캡처/전사 상태 분리. 중단된 manifest를 위해 관대한 디코딩 적용."
```

---

### Task 3: 트랙 시계 — 무음 삽입량 산출

캡처 콜백은 버퍼를 불규칙하게 준다. 슬립·드롭아웃으로 공백이 생기면 파일 시간축이 벽시계보다 짧아지고, 그대로 두면 전사 타임스탬프가 뒤로 갈수록 어긋난다. 이 타입이 "지금 무음을 몇 초 넣어야 하는가"를 계산한다.

**Files:**
- Create: `Sources/VoiceTypeCore/TrackClock.swift`
- Test: `Tests/VoiceTypeCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: `DiscontinuityRecord` (Task 2)
- Produces:
  - `struct TrackClock { init(sampleRate: Double, gapThreshold: Double) }`
  - `mutating func silenceNeeded(atWallTime: Double) -> Double?`
  - `mutating func advance(frameCount: Int)`
  - `var writtenSeconds: Double { get }`
  - `mutating func recordGap(wallTime: Double, gapSeconds: Double, reason: String) -> DiscontinuityRecord`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
final class TrackClockTests: XCTestCase {
    /// 16kHz에서 1600프레임 = 0.1초
    func testAdvanceAccumulatesWrittenSeconds() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 1600)
        XCTAssertEqual(c.writtenSeconds, 0.1, accuracy: 1e-9)
        c.advance(frameCount: 1600)
        XCTAssertEqual(c.writtenSeconds, 0.2, accuracy: 1e-9)
    }

    /// 벽시계와 기록량 차이가 임계값 이하면 무음을 넣지 않는다.
    func testNoSilenceWhenWithinThreshold() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)          // 1.0초 기록
        XCTAssertNil(c.silenceNeeded(atWallTime: 1.05))
    }

    /// 임계값을 넘으면 차이만큼 무음을 요구하고, 그만큼 기록량에 반영한다.
    func testSilenceInsertedWhenGapExceedsThreshold() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)          // 1.0초 기록
        let gap = c.silenceNeeded(atWallTime: 4.5)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap!, 3.5, accuracy: 1e-9)
        XCTAssertEqual(c.writtenSeconds, 4.5, accuracy: 1e-9)
        // 같은 시점에 다시 물으면 이미 메웠으므로 nil
        XCTAssertNil(c.silenceNeeded(atWallTime: 4.5))
    }

    /// 벽시계가 기록량보다 뒤인 경우(버퍼가 앞서 도착) 무음을 넣지 않는다.
    func testNoSilenceWhenWallTimeBehind() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)
        XCTAssertNil(c.silenceNeeded(atWallTime: 0.5))
        XCTAssertEqual(c.writtenSeconds, 1.0, accuracy: 1e-9)
    }

    /// recordGap은 silenceNeeded가 writtenSeconds를 이미 늘린 뒤에 호출되는 것을 전제로,
    /// gapSeconds를 되빼서 "무음을 넣기 전 지점"을 복원한다. 실제 호출 순서대로 검증한다.
    func testRecordGapProducesDiscontinuityAtPreGapFileTime() {
        var c = TrackClock(sampleRate: 16000, gapThreshold: 0.1)
        c.advance(frameCount: 16000)                    // 1.0초 기록
        let gap = c.silenceNeeded(atWallTime: 4.5)!     // 3.5초, writtenSeconds → 4.5
        let rec = c.recordGap(wallTime: 4.5, gapSeconds: gap, reason: "sleep_gap")
        XCTAssertEqual(rec.fileTime, 1.0, accuracy: 1e-9)   // 무음 넣기 전 지점
        XCTAssertEqual(rec.wallTime, 4.5, accuracy: 1e-9)
        XCTAssertEqual(rec.gapSeconds, 3.5, accuracy: 1e-9)
        XCTAssertEqual(rec.reason, "sleep_gap")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter TrackClockTests`
Expected: 컴파일 실패 — `cannot find 'TrackClock' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Sources/VoiceTypeCore/TrackClock.swift` 신규:

```swift
import Foundation

/// 한 트랙의 "기록된 시간"과 "실제 경과 시간"을 대조해, 메워야 할 무음 길이를 산출한다.
///
/// 캡처 콜백은 버퍼를 불규칙하게 전달하며 슬립·드롭아웃 시 아예 끊긴다.
/// 무음을 메우지 않으면 파일 시간축이 벽시계보다 짧아지고, 전사 타임스탬프가
/// 뒤로 갈수록 어긋난다. 파일 시간축을 항상 벽시계에 맞춰 두면
/// 전사 결과의 타임스탬프를 보정 없이 그대로 쓸 수 있다.
public struct TrackClock: Sendable {
    /// 목표 샘플레이트(Hz)
    public let sampleRate: Double
    /// 이 값을 넘는 공백만 불연속으로 처리한다(초). 미세한 지터까지 메우면 오히려 흔들린다.
    public let gapThreshold: Double

    /// 지금까지 파일에 기록된 길이(초)
    public private(set) var writtenSeconds: Double = 0

    public init(sampleRate: Double, gapThreshold: Double = 0.1) {
        self.sampleRate = sampleRate
        self.gapThreshold = gapThreshold
    }

    /// 실제 데이터를 기록한 뒤 호출한다.
    public mutating func advance(frameCount: Int) {
        writtenSeconds += Double(frameCount) / sampleRate
    }

    /// 버퍼를 쓰기 직전에 호출한다.
    /// 반환값이 있으면 그만큼 무음을 먼저 써야 하며, 그 길이는 이미 기록량에 반영된다.
    public mutating func silenceNeeded(atWallTime wallTime: Double) -> Double? {
        let gap = wallTime - writtenSeconds
        guard gap > gapThreshold else { return nil }
        writtenSeconds += gap
        return gap
    }

    /// 불연속 기록을 만든다. `fileTime`은 무음을 넣기 전 지점이어야 하므로 gap을 되돌려 계산한다.
    public mutating func recordGap(wallTime: Double,
                                   gapSeconds: Double,
                                   reason: String) -> DiscontinuityRecord {
        DiscontinuityRecord(fileTime: writtenSeconds - gapSeconds,
                            wallTime: wallTime,
                            gapSeconds: gapSeconds,
                            reason: reason)
    }
}
```

> **호출 순서 계약:** `recordGap`은 반드시 `silenceNeeded`가 `writtenSeconds`를 늘린 **뒤에** 불려야 한다. `gapSeconds`를 되빼서 무음 삽입 전 지점을 복원하기 때문이다. 순서를 뒤집으면 `fileTime`이 음수가 된다. `CAFWriter`(Task 5)가 이 순서를 지킨다.

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter TrackClockTests`
Expected: 5 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceTypeCore/TrackClock.swift Tests/VoiceTypeCoreTests/CoreTests.swift
git commit -m "feat(recorder): 트랙 시계 추가

벽시계 대비 기록량을 추적해 슬립·드롭아웃 공백에 넣을 무음 길이를 산출."
```

---

### Task 4: 회차 저장소

**Files:**
- Create: `Sources/VoiceType/RecordingStore.swift`
- Test: 없음 (파일시스템 의존 → Task 5의 CLI 검증 모드로 실측)

**Interfaces:**
- Consumes: `RecordingSession`, `RecordingID`, `TrackKind` (Task 1·2)
- Produces:
  - `RecordingStore.shared`
  - `var rootURL: URL { get set }`
  - `func createSession(startedAt: Date) throws -> (session: RecordingSession, folder: URL)`
  - `func save(_ session: RecordingSession, in folder: URL) throws`
  - `func load(from folder: URL) throws -> RecordingSession`
  - `func incompleteSessions() -> [(session: RecordingSession, folder: URL)]`
  - `func hasEnoughDiskSpace(at url: URL, requiredBytes: Int64) -> Bool`
  - `static let manifestName = "session.json"`

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/RecordingStore.swift` 신규:

```swift
import Foundation
import VoiceTypeCore

/// 녹음 회차 폴더와 manifest를 관리한다.
/// 받아쓰기 히스토리(~/Library/Application Support/VoiceType/)와 의도적으로 분리한다 —
/// 히스토리는 300건 cap·30일 만료로 자동 삭제되므로 녹음이 휩쓸려 날아갈 수 있다.
/// 녹음 파일에는 어떤 자동 삭제도 적용하지 않는다.
final class RecordingStore {
    static let shared = RecordingStore()

    static let manifestName = "session.json"

    /// 회차 폴더들이 놓이는 루트. 설정에서 변경 가능.
    var rootURL: URL

    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRoot
    }

    static var defaultRoot: URL {
        fmDocuments().appendingPathComponent("VoiceType Recordings", isDirectory: true)
    }

    private static func fmDocuments() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - 생성

    /// 새 회차 폴더를 만들고 초기 manifest를 쓴다.
    func createSession(startedAt: Date = Date()) throws -> (session: RecordingSession, folder: URL) {
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // 극히 드물지만 같은 초 + 같은 랜덤이 겹치면 다시 뽑는다
        var folder: URL
        var id: String
        var attempt = 0
        repeat {
            id = RecordingID.make(from: startedAt, random: RecordingID.randomSuffix())
            folder = rootURL.appendingPathComponent(id, isDirectory: true)
            attempt += 1
        } while fm.fileExists(atPath: folder.path) && attempt < 10
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)

        let session = RecordingSession(id: id, startedAt: startedAt, captureStatus: .recording)
        try save(session, in: folder)
        return (session, folder)
    }

    // MARK: - 입출력

    /// manifest를 원자적으로 교체한다. 녹음 중 크래시가 나도 반쯤 쓰인 JSON이 남지 않는다.
    func save(_ session: RecordingSession, in folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(session)
        try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    func load(from folder: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.manifestName))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RecordingSession.self, from: data)
    }

    // MARK: - 복구

    /// 캡처가 정상 종료되지 않은 회차들. 앱 시작 시 복구 제안에 쓴다.
    func incompleteSessions() -> [(session: RecordingSession, folder: URL)] {
        guard let entries = try? fm.contentsOfDirectory(at: rootURL,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { folder -> (RecordingSession, URL)? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard let s = try? load(from: folder), s.needsRecovery else { return nil }
            return (s, folder)
        }.sorted { $0.0.startedAt > $1.0.startedAt }
    }

    // MARK: - 디스크

    /// 녹음 시작 전·중 여유 공간 검사. 16kHz mono LPCM 2트랙은 시간당 약 230MB를 쓴다.
    func hasEnoughDiskSpace(at url: URL, requiredBytes: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true   // 알 수 없으면 막지 않는다
        }
        return available >= requiredBytes
    }

    /// 쓰기 가능 여부. 녹음 시작 전에 확인해 중간 실패를 막는다.
    func isWritable(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return fm.isWritableFile(atPath: url.path) }
        guard (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil else { return false }
        return fm.isWritableFile(atPath: url.path)
    }
}
```

- [ ] **Step 2: 빌드를 확인한다**

Run: `swift build`
Expected: 성공, 경고 0

- [ ] **Step 3: 커밋**

```bash
git add Sources/VoiceType/RecordingStore.swift
git commit -m "feat(recorder): 회차 저장소 추가

폴더 생성·manifest 원자적 입출력·미완료 세션 스캔·디스크 여유 검사.
히스토리 자동 삭제 로직과 분리."
```

---

### Task 5: CAF 라이터

**Files:**
- Create: `Sources/VoiceType/CAFWriter.swift`
- Test: 없음 (AVFoundation 의존 → Task 7의 CLI 모드로 실측)

**Interfaces:**
- Consumes: `TrackClock`, `DiscontinuityRecord` (Task 2·3)
- Produces:
  - `final class CAFWriter`
  - `init(url: URL, sampleRate: Double) throws`
  - `func write(_ data: Data, frameCount: Int, wallTime: Double)`
  - `func finish() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord])`
  - `var droppedBufferCount: Int { get }`

**설계 근거:** 녹음 중에는 `.caf` + LPCM으로 쓴다. `AVAssetWriter`의 m4a는 `moov` atom을 `finishWriting()` 시점에 파일 끝에 쓰므로, 크래시하면 파일이 통째로 파싱 불가가 된다. CAF LPCM은 헤더 확정이 필요 없어 마지막으로 쓰인 바이트까지 항상 유효하다.

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/CAFWriter.swift` 신규:

```swift
import Foundation
@preconcurrency import AVFoundation
import VoiceTypeCore

/// 16kHz mono 16-bit LPCM을 Core Audio Format(.caf)으로 기록한다.
///
/// 크래시 내성이 이 타입의 존재 이유다. m4a(AAC)는 프레임 인덱스(moov atom)를
/// 파일 끝에 쓰므로 강제 종료 시 전체가 읽히지 않는다. CAF LPCM은 헤더 확정이
/// 필요 없어 마지막으로 쓰인 바이트까지 항상 유효하다.
/// 정상 종료 후 AudioTranscoder가 m4a로 줄인다.
final class CAFWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var clock: TrackClock
    private var discontinuities: [DiscontinuityRecord] = []
    /// 캡처 콜백을 절대 막지 않기 위한 전용 직렬 큐
    private let queue: DispatchQueue
    /// 적체 카운터는 캡처 스레드(증가)와 쓰기 큐(감소) 양쪽에서 건드리므로 락으로 보호한다.
    private let counterLock = NSLock()
    private var _droppedBufferCount = 0
    private var _pendingCount = 0
    private let maxPending = 200   // 16kHz·0.1초 청크 기준 약 20초분

    /// 큐 적체 시 버린 버퍼 수 (manifest에 남긴다)
    var droppedBufferCount: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _droppedBufferCount
    }

    init(url: URL, sampleRate: Double = 16000) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: sampleRate,
                                      channels: 1,
                                      interleaved: true) else {
            throw NSError(domain: "CAFWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "오디오 포맷 생성 실패"])
        }
        format = fmt
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        clock = TrackClock(sampleRate: sampleRate)
        queue = DispatchQueue(label: "com.ion.voicetype.cafwriter.\(url.lastPathComponent)",
                              qos: .userInitiated)
    }

    /// 캡처 콜백에서 호출한다. 실제 파일 쓰기는 전용 큐로 넘겨 콜백을 막지 않는다.
    /// - Parameter wallTime: 세션 시작 기준 경과 초
    func write(_ data: Data, frameCount: Int, wallTime: Double) {
        counterLock.lock()
        if _pendingCount >= maxPending {
            _droppedBufferCount += 1
            counterLock.unlock()
            return
        }
        _pendingCount += 1
        counterLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.counterLock.lock()
                self._pendingCount -= 1
                self.counterLock.unlock()
            }
            self.writeSync(data, frameCount: frameCount, wallTime: wallTime)
        }
    }

    private func writeSync(_ data: Data, frameCount: Int, wallTime: Double) {
        // 공백이 임계값을 넘으면 무음을 먼저 채워 파일 시간축을 벽시계에 맞춘다
        if let gap = clock.silenceNeeded(atWallTime: wallTime) {
            let rec = clock.recordGap(wallTime: wallTime, gapSeconds: gap, reason: "capture_gap")
            discontinuities.append(rec)
            writeSilence(seconds: gap)
        }
        guard let buf = makeBuffer(from: data, frameCount: frameCount) else { return }
        try? file.write(from: buf)
        clock.advance(frameCount: frameCount)
    }

    private func makeBuffer(from data: Data, frameCount: Int) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let ch = buf.int16ChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frameCount)
        let byteCount = min(data.count, frameCount * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(ch[0], base, byteCount)
            }
        }
        return buf
    }

    private func writeSilence(seconds: Double) {
        let frames = Int(seconds * format.sampleRate)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.int16ChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        memset(ch[0], 0, frames * MemoryLayout<Int16>.size)
        try? file.write(from: buf)
    }

    /// 큐를 비우고 최종 길이·불연속 목록을 돌려준다.
    func finish() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord]) {
        queue.sync { }   // drain
        return (clock.writtenSeconds, discontinuities)
    }
}
```

- [ ] **Step 2: 빌드를 확인한다**

Run: `swift build`
Expected: 성공, 경고 0

- [ ] **Step 3: 커밋**

```bash
git add Sources/VoiceType/CAFWriter.swift
git commit -m "feat(recorder): CAF(LPCM) 라이터 추가

크래시 시 파일이 통째로 무효가 되는 m4a 대신 CAF로 녹음.
전용 직렬 큐로 캡처 콜백 비차단. 공백 임계값 초과 시 무음 삽입."
```

---

### Task 6: AudioCapture에 원시 PCM 콜백 확장

기존 `AudioCapture.onPCM`은 `Data`만 준다. CAF 라이터는 프레임 수와 호스트 시각이 필요하다.

**Files:**
- Modify: `Sources/VoiceType/AudioCapture.swift:20-23` (콜백 선언), `:107-145` (`process`)

**Interfaces:**
- Consumes: 없음
- Produces: `var onPCMDetailed: ((Data, Int, Double) -> Void)?` — (데이터, 프레임 수, 세션 시작 기준 경과 초)
- 기존 `onPCM`은 그대로 유지한다. 받아쓰기 경로가 쓰고 있다.

- [ ] **Step 1: 콜백과 기준 시각을 추가한다**

`Sources/VoiceType/AudioCapture.swift`의 `onLevel` 선언 아래에 추가:

```swift
    /// 변환된 PCM + 프레임 수 + 세션 시작 기준 경과 초. 녹음(CAFWriter)용.
    /// 기존 onPCM은 받아쓰기 STT 전송용으로 그대로 유지한다.
    var onPCMDetailed: ((Data, Int, Double) -> Void)?
    /// 경과 시각 산출 기준. start() 시점에 설정된다.
    private var sessionStartHostTime: UInt64 = 0
```

- [ ] **Step 2: start()에서 기준 시각을 잡는다**

`start(deviceID:recordingURL:)`의 `isRunning = true` 바로 위에 추가:

```swift
        sessionStartHostTime = mach_absolute_time()
```

파일 상단 import에 추가:

```swift
import Darwin
```

- [ ] **Step 3: process()에서 새 콜백을 호출한다**

`process(_:)` 안, `onPCM(data)` 호출 직후에 추가:

```swift
        if let onPCMDetailed = onPCMDetailed {
            onPCMDetailed(data, n, Self.secondsSince(sessionStartHostTime))
        }
```

파일 하단(클래스 안)에 헬퍼를 추가:

```swift
    /// mach_absolute_time 차이를 초로 환산한다. timebase는 한 번만 조회해 캐시한다.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func secondsSince(_ startHostTime: UInt64) -> Double {
        guard startHostTime != 0 else { return 0 }
        let delta = mach_absolute_time() &- startHostTime
        let nanos = Double(delta) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }
```

- [ ] **Step 4: 빌드와 기존 테스트를 확인한다**

Run: `swift build && swift test`
Expected: 빌드 성공, 기존 32개 테스트 전부 PASS (받아쓰기 경로 무손상 확인)

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceType/AudioCapture.swift
git commit -m "feat(recorder): AudioCapture에 상세 PCM 콜백 추가

프레임 수와 호스트시각 기준 경과 초를 함께 전달. 기존 onPCM 경로는 무변경."
```

---

### Task 7: 마이크 트랙 레코더 + CLI 검증 모드

이 태스크가 끝나면 **F5 없이도 마이크 녹음이 실제로 동작**한다. GUI·권한 없이 실측할 수 있는 첫 지점이다.

**Files:**
- Create: `Sources/VoiceType/MicTrackRecorder.swift`
- Modify: `Sources/VoiceType/AppMain.swift`

**Interfaces:**
- Consumes: `AudioCapture`, `CAFWriter`, `AudioDevices`, `SettingsStore`
- Produces:
  - `final class MicTrackRecorder`
  - `func start(to url: URL) throws`
  - `func stop() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int)`
  - `var onLevel: ((Float) -> Void)?`
  - `var isRunning: Bool { get }`

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/MicTrackRecorder.swift` 신규:

```swift
import Foundation
import VoiceTypeCore

/// 마이크 트랙 녹음. 기존 AudioCapture(AVAudioEngine)를 그대로 쓴다.
///
/// 이 경로는 화면 기록 권한이 필요 없고 macOS 14에서 동작하며 시작 지연이 밀리초다.
/// 시나리오 A(맥북만 들고 즉시 녹음)의 핵심이라, 어떤 경우에도 시스템 오디오
/// 실패에 끌려가 중단되면 안 된다.
final class MicTrackRecorder {
    private let capture = AudioCapture()
    private var writer: CAFWriter?

    var onLevel: ((Float) -> Void)?
    var isRunning: Bool { capture.isRunning }

    /// 설정의 마이크 우선순위를 적용해 녹음을 시작한다.
    func start(to url: URL) throws {
        let settings = SettingsStore.shared.settings
        // 우선순위에 일치하는 장치가 없으면 nil → 시스템 기본 입력이 쓰인다
        let device = AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                                          priority: settings.microphonePriority)
        let w = try CAFWriter(url: url)
        writer = w
        capture.onPCMDetailed = { [weak w] data, frames, wallTime in
            w?.write(data, frameCount: frames, wallTime: wallTime)
        }
        capture.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
        do {
            try capture.start(deviceID: device?.deviceID)
        } catch {
            capture.onPCMDetailed = nil
            capture.onLevel = nil
            writer = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int) {
        capture.stop()
        capture.onPCMDetailed = nil
        capture.onLevel = nil
        guard let w = writer else { return (0, [], 0) }
        let result = w.finish()
        let dropped = w.droppedBufferCount
        writer = nil
        return (result.durationSeconds, result.discontinuities, dropped)
    }
}
```

- [ ] **Step 2: CLI 검증 모드를 추가한다**

`Sources/VoiceType/AppMain.swift`의 기존 `--preview-indicator` 분기 옆에 같은 형태로 추가한다. 기존 분기가 `args.firstIndex(of:)`로 인자를 읽으므로 그 패턴을 따른다:

```swift
        if let idx = args.firstIndex(of: "--record-audio") {
            let seconds = (idx + 1 < args.count ? Double(args[idx + 1]) : nil) ?? 10
            RecordAudioCLI.run(seconds: seconds)
            return
        }
```

`Sources/VoiceType/MicTrackRecorder.swift` 파일 하단에 CLI 러너를 추가:

```swift
/// GUI 없이 마이크 녹음만 실측하는 검증 모드. `VoiceType --record-audio 30`
enum RecordAudioCLI {
    static func run(seconds: Double) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-record-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.caf")
        try? FileManager.default.removeItem(at: url)

        let rec = MicTrackRecorder()
        var peak: Float = 0
        rec.onLevel = { peak = max(peak, $0) }

        do {
            try rec.start(to: url)
        } catch {
            print("녹음 시작 실패: \(error.localizedDescription)")
            exit(1)
        }
        print("녹음 중… \(seconds)초. 목적지: \(url.path)")
        Thread.sleep(forTimeInterval: seconds)

        let r = rec.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("""
        ── 결과 ──
        기록 길이 : \(String(format: "%.2f", r.durationSeconds))초  (요청 \(seconds)초)
        파일 크기 : \(size ?? 0) bytes
        불연속    : \(r.discontinuities.count)건
        드롭 버퍼 : \(r.dropped)개
        입력 피크 : \(String(format: "%.4f", peak))
        """)
        for d in r.discontinuities {
            print("  gap \(String(format: "%.2f", d.gapSeconds))초 @ file \(String(format: "%.2f", d.fileTime))초 (\(d.reason))")
        }
        if peak < 0.001 { print("⚠️  입력 레벨이 0에 가깝다. 마이크 권한·라우팅을 확인할 것.") }
        exit(0)
    }
}
```

- [ ] **Step 3: 빌드한다**

Run: `swift build`
Expected: 성공

- [ ] **Step 4: 실측한다 (IÖN 수동 — 마이크 권한 필요)**

```bash
cd /Users/groovyroom/Development/260620_VoiceType && ./build_app.sh debug && .build/debug/VoiceType --record-audio 15
```

15초간 말하면서 확인할 것:
- `기록 길이`가 요청 초와 ±0.3초 이내인가
- `입력 피크`가 0.001보다 확실히 큰가 (0에 가까우면 마이크가 안 잡힌 것)
- `불연속` 0건, `드롭 버퍼` 0개
- `afplay /tmp/voicetype-record-test/mic.caf`로 재생해 소리가 들리는가

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceType/MicTrackRecorder.swift Sources/VoiceType/AppMain.swift
git commit -m "feat(recorder): 마이크 트랙 레코더 + CLI 검증 모드 추가

기존 마이크 우선순위 설정 그대로 적용. --record-audio <초>로 GUI 없이 실측 가능."
```

---

### Task 8: CAF → m4a 트랜스코더

**Files:**
- Create: `Sources/VoiceType/AudioTranscoder.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `enum AudioTranscoder`, `static func toM4A(from: URL, to: URL) async throws`

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/AudioTranscoder.swift` 신규:

```swift
import Foundation
@preconcurrency import AVFoundation

/// 녹음 종료 후 CAF(LPCM) → 16kHz mono AAC(m4a) 변환.
/// 녹음 중에는 크래시 내성 때문에 CAF를 쓰고, 정상 종료 시에만 용량을 줄인다.
/// 시간당 약 230MB → 약 14MB.
enum AudioTranscoder {
    enum TranscodeError: LocalizedError {
        case exportSessionUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .exportSessionUnavailable: return "오디오 변환 세션을 만들지 못했습니다."
            case .failed(let m):            return "오디오 변환 실패: \(m)"
            }
        }
    }

    static func toM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscodeError.exportSessionUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        if export.status == .failed {
            throw TranscodeError.failed(export.error?.localizedDescription ?? "알 수 없는 오류")
        }
    }
}
```

- [ ] **Step 2: 빌드한다**

Run: `swift build`
Expected: 성공. `AVAssetExportSession.export()`의 async 형태가 배포 타겟에서 안 잡히면 아래로 대체한다:

```swift
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
```

- [ ] **Step 3: 실측한다**

```bash
.build/debug/VoiceType --record-audio 5
```
로 만든 `mic.caf`를 변환해 재생 가능한지 확인한다. 확인 방법은 Task 9 완료 후 회차 폴더에서 자동으로 검증된다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/VoiceType/AudioTranscoder.swift
git commit -m "feat(recorder): CAF→m4a 트랜스코더 추가

정상 종료 시에만 실행해 시간당 230MB를 14MB로 줄인다."
```

---

### Task 9: 시스템 오디오 트랙 레코더

**Files:**
- Create: `Sources/VoiceType/SystemTrackRecorder.swift`
- Modify: `Info.plist`

**Interfaces:**
- Consumes: `CAFWriter`, `AudioCapture.secondsSince` (Task 5·6)
- Produces:
  - `final class SystemTrackRecorder: NSObject, SCStreamOutput, SCStreamDelegate`
  - `func start(to url: URL) async throws`
  - `func stop() async -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int)`
  - `var onLevel: ((Float) -> Void)?`
  - `var onFailure: ((String) -> Void)?`
  - `static func hasPermission() async -> Bool`

**Global Constraints 재확인:** `captureMicrophone`·`microphoneCaptureDeviceID`·`SCStreamOutputTypeMicrophone`를 **쓰지 않는다.** `capturesAudio`만 쓴다(macOS 13+).

- [ ] **Step 1: Info.plist에 사용 설명을 추가한다**

`Info.plist`의 `NSMicrophoneUsageDescription` 바로 아래에 추가:

```xml
	<key>NSScreenCaptureUsageDescription</key>
	<string>회의 녹음 시 컴퓨터에서 나는 소리를 함께 녹음하기 위해 필요합니다. 오디오만 사용하며 화면은 녹화하지 않습니다.</string>
```

- [ ] **Step 2: 구현을 쓴다**

`Sources/VoiceType/SystemTrackRecorder.swift` 신규:

```swift
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import VoiceTypeCore

/// 시스템 오디오(컴퓨터에서 나는 소리) 트랙 녹음.
///
/// 마이크는 MicTrackRecorder가 별도로 담당한다. 여기서 captureMicrophone(macOS 15+)을
/// 쓰지 않는 이유는 배포 타겟 macOS 14를 유지하기 위해서다. capturesAudio는 macOS 13+다.
///
/// 이 레이어의 실패는 녹음 실패가 아니다. 화면 기록 권한이 없거나 스트림이 죽어도
/// 마이크 트랙은 계속되어야 하므로, 실패는 onFailure로만 알리고 예외를 위로 던지지 않는다.
final class SystemTrackRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: CAFWriter?
    private var startHostTime: UInt64 = 0
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let sampleQueue = DispatchQueue(label: "com.ion.voicetype.scstream.audio", qos: .userInitiated)

    var onLevel: ((Float) -> Void)?
    /// 스트림이 중간에 죽었을 때 호출. 녹음 자체는 계속된다.
    var onFailure: ((String) -> Void)?

    override init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000,
                                     channels: 1,
                                     interleaved: true)!
        super.init()
    }

    /// 화면 기록 권한이 있는지 확인한다. 권한이 없으면 콘텐츠 조회가 실패한다.
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                     onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func start(to url: URL) async throws {
        // 오디오만 필요하지만 SCStream은 유효한 SCContentFilter를 요구한다.
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemTrackRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "캡처 가능한 디스플레이가 없습니다."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // 자기 자신의 소리는 제외한다 (디지털 경로만. 스피커 물리 누설은 막지 못한다)
        config.excludesCurrentProcessAudio = true
        // 영상은 버리지만 SCStream이 프레임을 만들긴 하므로 비용을 최소화한다.
        // .screen 출력은 등록하지 않아 프레임이 시스템 단계에서 폐기되게 한다.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let w = try CAFWriter(url: url)
        writer = w

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
        startHostTime = mach_absolute_time()
    }

    func stop() async -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int) {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        guard let w = writer else { return (0, [], 0) }
        let result = w.finish()
        let dropped = w.droppedBufferCount
        writer = nil
        return (result.durationSeconds, result.discontinuities, dropped)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        guard let converted = convert(pcm) else { return }
        guard let ch = converted.int16ChannelData, converted.frameLength > 0 else { return }

        let n = Int(converted.frameLength)
        let data = Data(bytes: ch[0], count: n * MemoryLayout<Int16>.size)
        writer?.write(data, frameCount: n, wallTime: AudioCapture.secondsSince(startHostTime))

        if let onLevel = onLevel {
            var sum: Float = 0
            for i in 0..<n {
                let v = Float(ch[0][i]) / 32768.0
                sum += v * v
            }
            let rms = (sum / Float(n)).squareRoot()
            DispatchQueue.main.async { onLevel(rms) }
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer. SCStream은 Float32 non-interleaved로 준다.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }

    /// 입력 포맷은 장치·라우팅 변경으로 도중에 바뀔 수 있으므로 컨버터를 그때마다 재생성한다.
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converter = converter else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return err == nil ? out : nil
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onFailure?("시스템 오디오 녹음이 중단됐습니다: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 3: 빌드한다**

Run: `swift build`
Expected: 성공. `@preconcurrency import ScreenCaptureKit`으로도 Sendable 경고가 나면 콜백 내부를 `MainActor.assumeIsolated`로 감싸는 대신 해당 프로퍼티를 `nonisolated(unsafe)`로 표시한다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/VoiceType/SystemTrackRecorder.swift Info.plist
git commit -m "feat(recorder): 시스템 오디오 트랙 레코더 추가

capturesAudio(macOS 13+)만 사용해 배포 타겟 14 유지.
스트림 실패는 onFailure로만 알리고 마이크 트랙을 중단시키지 않는다."
```

---

### Task 10: 전원 어서션

90분 녹음이 디스플레이 슬립으로 끊기는 것을 막는다.

**Files:**
- Create: `Sources/VoiceType/PowerAssertion.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `final class PowerAssertion`, `func acquire(reason: String)`, `func release()`

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/PowerAssertion.swift` 신규:

```swift
import Foundation
import IOKit.pwr_mgt

/// 녹음 중 디스플레이·시스템 절전을 막는다.
/// 이게 없으면 회의 도중 화면이 꺼지면서 시스템 오디오 캡처가 멈춘다.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func acquire(reason: String) {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        held = (result == kIOReturnSuccess)
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }

    deinit { release() }
}
```

- [ ] **Step 2: 빌드한다**

Run: `swift build`
Expected: 성공

- [ ] **Step 3: 커밋**

```bash
git add Sources/VoiceType/PowerAssertion.swift
git commit -m "feat(recorder): 전원 어서션 추가

녹음 중 디스플레이 절전으로 시스템 오디오 캡처가 끊기는 것을 방지."
```

---

### Task 11: 녹음 컨트롤러

두 레이어를 조율하는 상태 머신.

**Files:**
- Create: `Sources/VoiceType/RecorderController.swift`

**Interfaces:**
- Consumes: 전 태스크 전부
- Produces:
  - `@MainActor final class RecorderController`
  - `enum State { case idle, starting, recording, stopping, finalizing }`
  - `func toggle()`
  - `var state: State { get }`
  - `var onStateChange: ((State) -> Void)?`
  - `var onError: ((String) -> Void)?`
  - `var onMicLevel: ((Float) -> Void)?`
  - `var onSystemLevel: ((Float) -> Void)?`
  - `var onFinished: ((URL) -> Void)?`  // 완료된 회차 폴더
  - `var elapsedSeconds: Double { get }`
  - `var isRecording: Bool { get }`

- [ ] **Step 1: 구현을 쓴다**

`Sources/VoiceType/RecorderController.swift` 신규:

```swift
import Foundation
import AppKit
import VoiceTypeCore

/// F5 녹음 전체 흐름 제어.
///
/// 핵심 규칙: 마이크 트랙은 어떤 경우에도 시스템 오디오 실패에 끌려가지 않는다.
/// 시스템 오디오는 "되면 얹히는" 부가 레이어다.
@MainActor
final class RecorderController {
    enum State { case idle, starting, recording, stopping, finalizing }

    private(set) var state: State = .idle

    private let mic = MicTrackRecorder()
    private var system: SystemTrackRecorder?
    private let power = PowerAssertion()
    private let store = RecordingStore.shared

    private var session: RecordingSession?
    private var folder: URL?
    private var startedAt: Date?
    private var diskTimer: Timer?

    /// 녹음 시작 최소 여유 공간 — LPCM 2트랙 2시간분 + 여유
    private static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?
    var onFinished: ((URL) -> Void)?

    var isRecording: Bool { state == .recording }
    var elapsedSeconds: Double {
        guard let startedAt = startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - 토글

    func toggle() {
        switch state {
        case .idle:       start()
        case .recording:  Task { await stop() }
        default:          break   // starting/stopping/finalizing 중엔 무시
        }
    }

    // MARK: - 시작

    private func start() {
        setState(.starting)

        guard store.isWritable(store.rootURL) else {
            onError?("녹음 폴더에 쓸 수 없습니다: \(store.rootURL.path)\n설정에서 다른 폴더를 지정하세요.")
            setState(.idle)
            return
        }
        guard store.hasEnoughDiskSpace(at: store.rootURL, requiredBytes: Self.minFreeBytes) else {
            onError?("디스크 여유 공간이 부족합니다. 최소 2GB가 필요합니다.")
            setState(.idle)
            return
        }

        AudioCapture.requestPermission { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard ok else {
                    self.onError?("마이크 권한이 거부되었습니다. 시스템 설정 > 개인정보 보호 > 마이크에서 허용하세요.")
                    self.setState(.idle)
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let now = Date()
        let created: (session: RecordingSession, folder: URL)
        do {
            created = try store.createSession(startedAt: now)
        } catch {
            onError?("녹음 폴더 생성 실패: \(error.localizedDescription)")
            setState(.idle)
            return
        }
        session = created.session
        folder = created.folder
        startedAt = now

        // 레이어 1 — 마이크. 실패하면 녹음 자체가 실패다.
        mic.onLevel = { [weak self] in self?.onMicLevel?($0) }
        do {
            try mic.start(to: created.folder.appendingPathComponent("mic.caf"))
        } catch {
            onError?("마이크 녹음 시작 실패: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: created.folder)
            resetAll()
            setState(.idle)
            return
        }

        power.acquire(reason: "VoiceType 녹음 중")
        startDiskWatch()
        setState(.recording)

        // 레이어 2 — 시스템 오디오. 실패해도 마이크는 계속된다.
        Task { [weak self] in
            guard let self = self else { return }
            await self.attachSystemTrack(in: created.folder)
        }
    }

    private func attachSystemTrack(in folder: URL) async {
        guard await SystemTrackRecorder.hasPermission() else {
            onError?("화면 기록 권한이 없어 컴퓨터 소리는 녹음되지 않습니다. 마이크 녹음은 계속됩니다.\n시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 VoiceType을 허용하세요.")
            return
        }
        let rec = SystemTrackRecorder()
        rec.onLevel = { [weak self] in self?.onSystemLevel?($0) }
        rec.onFailure = { [weak self] msg in
            MainActor.assumeIsolated { self?.onError?(msg) }
        }
        do {
            try await rec.start(to: folder.appendingPathComponent("system.caf"))
            system = rec
        } catch {
            onError?("컴퓨터 소리 녹음을 시작하지 못했습니다. 마이크 녹음은 계속됩니다.\n\(error.localizedDescription)")
        }
    }

    // MARK: - 디스크 감시

    private func startDiskWatch() {
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.state == .recording else { return }
                if !self.store.hasEnoughDiskSpace(at: self.store.rootURL,
                                                  requiredBytes: 300 * 1024 * 1024) {
                    self.onError?("디스크 여유 공간이 부족해 녹음을 종료합니다.")
                    await self.stop()
                }
            }
        }
    }

    // MARK: - 종료

    private func stop() async {
        guard state == .recording, let folder = folder, var session = session else { return }
        setState(.stopping)
        diskTimer?.invalidate(); diskTimer = nil
        power.release()

        let micResult = mic.stop()
        let sysResult = await system?.stop()
        system = nil

        setState(.finalizing)

        var tracks: [TrackInfo] = []
        // CAF → m4a 변환. 실패하면 CAF를 그대로 남긴다 — 원본을 절대 먼저 지우지 않는다.
        if let info = await finalizeTrack(.mic, in: folder,
                                          duration: micResult.durationSeconds,
                                          discontinuities: micResult.discontinuities) {
            tracks.append(info)
        }
        if let sys = sysResult, sys.durationSeconds > 0,
           let info = await finalizeTrack(.system, in: folder,
                                          duration: sys.durationSeconds,
                                          discontinuities: sys.discontinuities) {
            tracks.append(info)
        }

        session.tracks = tracks
        session.durationSeconds = micResult.durationSeconds
        session.captureStatus = tracks.isEmpty ? .failed : .done
        // 전사는 다음 계획의 범위 — 여기서는 대기 상태로 남긴다
        session.transcriptionStatus = .pending
        try? store.save(session, in: folder)

        self.session = nil
        self.folder = nil
        self.startedAt = nil
        setState(.idle)
        onFinished?(folder)
    }

    /// CAF를 m4a로 바꾸고 TrackInfo를 만든다. 변환 실패 시 CAF 파일명을 그대로 쓴다.
    private func finalizeTrack(_ kind: TrackKind,
                               in folder: URL,
                               duration: Double,
                               discontinuities: [DiscontinuityRecord]) async -> TrackInfo? {
        let base = kind.rawValue
        let caf = folder.appendingPathComponent("\(base).caf")
        guard FileManager.default.fileExists(atPath: caf.path) else { return nil }
        let m4a = folder.appendingPathComponent("\(base).m4a")
        do {
            try await AudioTranscoder.toM4A(from: caf, to: m4a)
            try? FileManager.default.removeItem(at: caf)
            return TrackInfo(kind: kind, fileName: "\(base).m4a",
                             durationSeconds: duration, discontinuities: discontinuities)
        } catch {
            onError?("\(base) 변환에 실패해 원본(caf)을 그대로 보관합니다: \(error.localizedDescription)")
            return TrackInfo(kind: kind, fileName: "\(base).caf",
                             durationSeconds: duration, discontinuities: discontinuities)
        }
    }

    private func resetAll() {
        session = nil; folder = nil; startedAt = nil
        diskTimer?.invalidate(); diskTimer = nil
        power.release()
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }
}
```

- [ ] **Step 2: 빌드한다**

Run: `swift build && swift test`
Expected: 빌드 성공, 기존 테스트 전부 PASS

- [ ] **Step 3: 커밋**

```bash
git add Sources/VoiceType/RecorderController.swift
git commit -m "feat(recorder): 녹음 컨트롤러 추가

2레이어 조율·전원 어서션·디스크 감시·CAF→m4a 마감.
시스템 오디오 실패가 마이크 트랙을 중단시키지 않도록 분리."
```

---

### Task 12: AppDelegate 통합 — F5 핫키

**Files:**
- Modify: `Sources/VoiceType/AppDelegate.swift` (`:8` 프로퍼티, `:165-185` `setupHotkey`, `:216-222` `registerProfileHotkeys`, `:93-105` `updateIcon`)
- Modify: `Sources/VoiceType/DictationController.swift` (`:28` `trigger`)
- Modify: `Sources/VoiceTypeCore/AppSettings.swift`

**Interfaces:**
- Consumes: `RecorderController` (Task 11)
- Produces: `AppSettings.recordingHotkeyKeyCode`(기본 96 = F5), `.recordingHotkeyModifiers`, `.recordingFolderPath`
- 예약 핫키 id: `AppDelegate.recordingHotkeyID: UInt32 = 9000`. 프로파일은 배열 인덱스를 id로 쓰므로 충돌하지 않는다.

- [ ] **Step 1: 실패하는 테스트를 먼저 쓴다**

`Tests/VoiceTypeCoreTests/CoreTests.swift` 끝에 추가:

```swift
final class RecordingSettingsTests: XCTestCase {
    /// 기존 settings.json에는 녹음 필드가 없다. 기본값이 채워지고 기존 값은 살아남아야 한다.
    func testLegacySettingsGainRecordingDefaults() throws {
        let json = """
        {"autoPaste":true,"profiles":[{"id":"\(UUID().uuidString)","name":"받아쓰기",
        "hotkeyKeyCode":100,"hotkeyModifiers":0,"useLLM":true,"instruction":"x",
        "triggerMode":"toggle"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.recordingHotkeyKeyCode, 96)   // F5
        XCTAssertEqual(s.recordingHotkeyModifiers, 0)
        XCTAssertEqual(s.recordingFolderPath, "")
        XCTAssertEqual(s.profiles.count, 1)
        XCTAssertEqual(s.profiles.first?.name, "받아쓰기")
    }

    func testRecordingHotkeyRoundTrips() throws {
        var s = AppSettings()
        s.recordingHotkeyKeyCode = 97
        s.recordingFolderPath = "/tmp/rec"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.recordingHotkeyKeyCode, 97)
        XCTAssertEqual(back.recordingFolderPath, "/tmp/rec")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter RecordingSettingsTests`
Expected: 컴파일 실패 — `value of type 'AppSettings' has no member 'recordingHotkeyKeyCode'`

- [ ] **Step 3: 설정 필드를 추가한다**

`Sources/VoiceTypeCore/AppSettings.swift`에 프로퍼티·init 파라미터·CodingKeys·관대한 디코딩을 기존 `saveRecordings` 패턴 그대로 추가한다:

```swift
    /// F5 녹음 핫키 (Carbon keyCode). 96 = F5.
    public var recordingHotkeyKeyCode: UInt32
    public var recordingHotkeyModifiers: UInt32
    /// 녹음 회차 폴더 루트. 빈 문자열이면 기본값(~/Documents/VoiceType Recordings).
    public var recordingFolderPath: String
```

init 기본값: `recordingHotkeyKeyCode: UInt32 = 96, recordingHotkeyModifiers: UInt32 = 0, recordingFolderPath: String = ""`

CodingKeys에 세 키를 추가하고, `init(from:)`에:

```swift
        recordingHotkeyKeyCode = (try? c.decode(UInt32.self, forKey: .recordingHotkeyKeyCode)) ?? 96
        recordingHotkeyModifiers = (try? c.decode(UInt32.self, forKey: .recordingHotkeyModifiers)) ?? 0
        recordingFolderPath = (try? c.decode(String.self, forKey: .recordingFolderPath)) ?? ""
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter RecordingSettingsTests`
Expected: 2 tests PASS

- [ ] **Step 5: AppDelegate에 컨트롤러와 핫키를 붙인다**

`AppDelegate` 프로퍼티에 추가:

```swift
    private let recorder = RecorderController()
    static let recordingHotkeyID: UInt32 = 9000
```

`registerProfileHotkeys()`를 아래로 교체:

```swift
    private func registerProfileHotkeys() {
        let s = SettingsStore.shared.settings
        var keys = s.profiles.enumerated().map {
            (id: UInt32($0.offset), keyCode: $0.element.hotkeyKeyCode, modifiers: $0.element.hotkeyModifiers)
        }
        // 녹음 핫키는 예약 id로 등록 — 프로파일 인덱스(0..n)와 충돌하지 않는다
        keys.append((id: Self.recordingHotkeyID,
                     keyCode: s.recordingHotkeyKeyCode,
                     modifiers: s.recordingHotkeyModifiers))
        hotkey.registerAll(keys)
    }
```

`setupHotkey()`의 `onTrigger` 클로저 맨 앞에 분기를 추가:

```swift
            if id == Self.recordingHotkeyID {
                self.recorder.toggle()
                return
            }
```

`onRelease` 클로저 맨 앞에도 무시 분기를 추가한다 (녹음은 토글이라 release를 쓰지 않는다):

```swift
            if id == Self.recordingHotkeyID { return }
```

`applicationDidFinishLaunching`의 `setupHotkey()` 호출 아래에 추가:

```swift
        setupRecorder()
```

`setupDictation()` 아래에 새 메서드를 추가:

```swift
    private func setupRecorder() {
        // 설정에 지정된 폴더를 저장소에 반영
        let path = SettingsStore.shared.settings.recordingFolderPath
        if !path.isEmpty {
            RecordingStore.shared.rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        recorder.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.updateRecordingIcon(state)
            switch state {
            case .recording:
                self.indicator.setStyle(SettingsStore.shared.settings.indicatorStyle)
                self.indicator.setMode(.recording)
                self.indicator.setCaption(self.l.text("recorder.indicator.recording"))
                self.indicator.show()
            case .stopping, .finalizing:
                self.indicator.setMode(.processing)
                self.indicator.setCaption(self.l.text("recorder.indicator.finalizing"))
            case .idle:
                self.indicator.hide()
            case .starting:
                break
            }
        }
        recorder.onError = { [weak self] msg in self?.notify(msg) }
        recorder.onMicLevel = { [weak self] level in self?.indicator.setLevel(level) }
        recorder.onFinished = { folder in
            NSWorkspace.shared.activateFileViewerSelecting([folder])
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
```

- [ ] **Step 5: 녹음 중 받아쓰기를 차단한다**

`AppDelegate`에 접근자를 추가:

```swift
    var isRecordingMeeting: Bool { recorder.isRecording }
```

`setupHotkey()`의 `onTrigger`에서 프로파일 분기 직전에 추가:

```swift
            if self.recorder.isRecording {
                self.notify(self.l.text("recorder.dictation_blocked"))
                return
            }
```

`setupSpaceTrigger()`의 `onActivate` 클로저 맨 앞에도 추가:

```swift
            guard !self.recorder.isRecording else { return }
```

- [ ] **Step 6: 현지화 문자열을 추가한다**

`Sources/VoiceType/Resources/ko.lproj/Localizable.strings`:

```
"recorder.indicator.recording" = "녹음 중";
"recorder.indicator.finalizing" = "저장 중";
"recorder.dictation_blocked" = "녹음 중에는 받아쓰기를 사용할 수 없습니다. F5로 녹음을 먼저 종료하세요.";
```

`Sources/VoiceType/Resources/en.lproj/Localizable.strings`:

```
"recorder.indicator.recording" = "Recording";
"recorder.indicator.finalizing" = "Saving";
"recorder.dictation_blocked" = "Dictation is unavailable while recording. Press F5 to stop the recording first.";
```

- [ ] **Step 7: 빌드하고 전체 테스트를 돌린다**

Run: `swift build && swift test`
Expected: 빌드 성공 경고 0, 기존 32개 + 신규 테스트 전부 PASS

- [ ] **Step 8: 커밋**

```bash
git add Sources/VoiceType/AppDelegate.swift Sources/VoiceTypeCore/AppSettings.swift \
        Sources/VoiceType/Resources/ko.lproj/Localizable.strings \
        Sources/VoiceType/Resources/en.lproj/Localizable.strings \
        Tests/VoiceTypeCoreTests/CoreTests.swift
git commit -m "feat(recorder): F5 핫키 통합

예약 id 9000으로 프로파일 핫키와 분리 등록.
녹음 중 받아쓰기·스페이스바 트리거 차단."
```

---

### Task 13: 미완료 세션 복구

**Files:**
- Modify: `Sources/VoiceType/AppDelegate.swift` (`applicationDidFinishLaunching`)
- Modify: `Sources/VoiceType/RecorderController.swift`

**Interfaces:**
- Consumes: `RecordingStore.incompleteSessions()` (Task 4)
- Produces: `RecorderController.recoverIncompleteSessions() async -> Int` (복구한 건수)

- [ ] **Step 1: 복구 메서드를 추가한다**

`RecorderController`에 추가:

```swift
    /// 앱 시작 시 호출. 캡처가 정상 종료되지 않은 회차의 CAF를 m4a로 마감한다.
    /// 크래시로 남은 CAF는 마지막 바이트까지 유효하므로 그대로 변환하면 된다.
    @discardableResult
    func recoverIncompleteSessions() async -> Int {
        let pending = store.incompleteSessions()
        guard !pending.isEmpty else { return 0 }
        var recovered = 0
        for (var session, folder) in pending {
            var tracks: [TrackInfo] = []
            for kind in TrackKind.allCases {
                let caf = folder.appendingPathComponent("\(kind.rawValue).caf")
                guard FileManager.default.fileExists(atPath: caf.path) else { continue }
                let duration = Self.cafDuration(at: caf)
                if let info = await finalizeTrack(kind, in: folder,
                                                  duration: duration, discontinuities: []) {
                    tracks.append(info)
                }
            }
            // 기존 m4a가 이미 있는 경우(변환 후 크래시)도 트랙으로 인정한다
            for kind in TrackKind.allCases where !tracks.contains(where: { $0.kind == kind }) {
                let m4a = folder.appendingPathComponent("\(kind.rawValue).m4a")
                if FileManager.default.fileExists(atPath: m4a.path) {
                    tracks.append(TrackInfo(kind: kind, fileName: "\(kind.rawValue).m4a",
                                            durationSeconds: 0, discontinuities: []))
                }
            }
            session.tracks = tracks
            session.captureStatus = tracks.isEmpty ? .failed : .done
            session.durationSeconds = tracks.first?.durationSeconds ?? 0
            try? store.save(session, in: folder)
            if !tracks.isEmpty { recovered += 1 }
        }
        return recovered
    }

    /// CAF 길이를 파일에서 직접 읽는다(크래시로 manifest에 안 남은 경우).
    private static func cafDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
```

`RecorderController.swift` 상단 import에 추가:

```swift
@preconcurrency import AVFoundation
```

- [ ] **Step 2: 앱 시작 시 호출한다**

`applicationDidFinishLaunching`의 온보딩 분기 **앞**에 추가:

```swift
        Task { @MainActor in
            let n = await self.recorder.recoverIncompleteSessions()
            if n > 0 {
                self.notify(String(format: self.l.text("recorder.recovered"), n))
            }
        }
```

현지화 문자열 추가 — `ko.lproj`:

```
"recorder.recovered" = "정상 종료되지 않은 녹음 %d건을 복구했습니다.";
```

`en.lproj`:

```
"recorder.recovered" = "Recovered %d recording(s) that did not finish normally.";
```

- [ ] **Step 3: 빌드한다**

Run: `swift build && swift test`
Expected: 전부 통과

- [ ] **Step 4: 강제 종료 복구를 실측한다 (IÖN 수동)**

```bash
cd /Users/groovyroom/Development/260620_VoiceType && ./build_app.sh debug install
```

1. F5로 녹음 시작, 10초 정도 말한다
2. 활성 상태 보기에서 VoiceType를 **강제 종료**한다
3. 앱을 다시 실행한다
4. "정상 종료되지 않은 녹음 1건을 복구했습니다" 알림이 뜨는지 확인
5. `~/Documents/VoiceType Recordings/<회차>/mic.m4a`가 재생되는지 확인

- [ ] **Step 5: 커밋**

```bash
git add Sources/VoiceType/RecorderController.swift Sources/VoiceType/AppDelegate.swift \
        Sources/VoiceType/Resources/ko.lproj/Localizable.strings \
        Sources/VoiceType/Resources/en.lproj/Localizable.strings
git commit -m "feat(recorder): 미완료 세션 복구 추가

앱 시작 시 크래시로 남은 CAF를 m4a로 마감하고 manifest를 확정."
```

---

### Task 14: 인디케이터 2트랙 VU 미터

권한·라우팅 실패로 90분 무음을 녹음하는 사고를 막는 유일한 수단이다.

**Files:**
- Modify: `Sources/VoiceType/RecordingIndicator.swift`
- Modify: `Sources/VoiceType/AppDelegate.swift` (`setupRecorder`)

**Interfaces:**
- Consumes: `RecordingIndicatorController` (기존)
- Produces:
  - `RecordingIndicatorController.setSecondaryLevel(_ level: Float)`
  - `RecordingIndicatorController.setShowsSecondaryLevel(_ shows: Bool)`
  - `RecordingIndicatorController.setElapsed(_ seconds: Double)`

- [ ] **Step 1: 인디케이터 모델에 보조 레벨과 경과 시간을 추가한다**

`RecordingIndicator.swift`의 뷰모델(`@Published var style` 근처)에 추가:

```swift
    /// 시스템 오디오 레벨 (0~1). 녹음 모드에서만 표시.
    @Published var secondaryLevel: Float = 0
    /// 보조 레벨 막대를 표시할지 (시스템 오디오 트랙이 붙었을 때만 true)
    @Published var showsSecondaryLevel: Bool = false
    /// 경과 시간 표시 문자열. 빈 문자열이면 표시하지 않는다.
    @Published var elapsedText: String = ""
```

`RecordingIndicatorController`에 전달 메서드를 추가:

```swift
    func setSecondaryLevel(_ level: Float) { model.secondaryLevel = level }
    func setShowsSecondaryLevel(_ shows: Bool) { model.showsSecondaryLevel = shows }

    /// 경과 초를 mm:ss(1시간 넘으면 h:mm:ss)로 표시한다.
    func setElapsed(_ seconds: Double) {
        guard seconds > 0 else { model.elapsedText = ""; return }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        model.elapsedText = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
```

기존 캡션 뷰 옆에 경과 시간과 보조 막대를 그린다. `WaveformIndicator` 등 각 스타일 뷰의 캡션 `Text` 뒤에 추가:

```swift
                if !model.elapsedText.isEmpty {
                    Text(model.elapsedText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.showsSecondaryLevel {
                    // 시스템 오디오 레벨 — 마이크 막대와 구분되게 파란 계열
                    Capsule()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 3 + CGFloat(model.secondaryLevel) * 40, height: 3)
                }
```

- [ ] **Step 2: 컨트롤러를 연결한다**

`AppDelegate.setupRecorder()`에 추가:

```swift
        recorder.onSystemLevel = { [weak self] level in
            self?.indicator.setShowsSecondaryLevel(true)
            self?.indicator.setSecondaryLevel(level)
        }
```

경과 시간 갱신 타이머를 `setupRecorder()`에 추가:

```swift
        recorder.onStateChange = { [weak self] state in
            // ... 기존 분기 유지 ...
            switch state {
            case .recording:
                self?.startElapsedTimer()
            case .idle, .stopping, .finalizing:
                self?.stopElapsedTimer()
            case .starting:
                break
            }
        }
```

`AppDelegate`에 타이머를 추가:

```swift
    private var elapsedTimer: Timer?

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
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
```

> **주의:** Step 1에서 `onStateChange`를 두 번 대입하면 뒤엣것이 앞엣것을 덮어쓴다. Task 12에서 쓴 `onStateChange` 클로저 **하나**에 타이머 호출을 합쳐 넣을 것.

- [ ] **Step 3: 빌드하고 시각 검증한다**

Run: `swift build && ./build_app.sh debug && .build/debug/VoiceType --preview-indicator waveform`
Expected: 인디케이터가 뜨고 레이아웃이 깨지지 않는다

- [ ] **Step 4: 커밋**

```bash
git add Sources/VoiceType/RecordingIndicator.swift Sources/VoiceType/AppDelegate.swift
git commit -m "feat(recorder): 인디케이터에 경과 시간·시스템 오디오 레벨 추가

무음 녹음 사고를 녹음 중에 눈으로 잡을 수 있게 함."
```

---

### Task 15: 통합 실측 (IÖN 수동)

코드 변경 없음. 이 계획의 산출물이 실제로 동작하는지 확인하는 게이트다.

- [ ] **Step 1: 릴리스 빌드를 설치한다**

```bash
cd /Users/groovyroom/Development/260620_VoiceType && ./build_app.sh release install
```

- [ ] **Step 2: 시나리오 A — 즉석 녹음 (화면 권한 없이)**

시스템 설정에서 VoiceType의 화면 기록 권한을 **끈 상태**로:

1. F5를 누른다 → 즉시 녹음이 시작되는가 (지연·대화상자 없이)
2. "화면 기록 권한 없음" 안내가 뜨되 **녹음은 계속되는가**
3. 20초 말한 뒤 F5 → Finder에 회차 폴더가 열리는가
4. `mic.m4a`만 있고 `system.m4a`는 없는가
5. `session.json`의 `captureStatus`가 `done`인가

- [ ] **Step 3: 시나리오 B — 온라인 회의**

화면 기록 권한을 켠 뒤:

1. Google Meet 또는 Discord 통화를 연결한다
2. F5 → 녹음 시작. 인디케이터에 **막대 2개**(마이크·시스템)가 다 움직이는가
3. 서로 번갈아 말한 뒤 F5
4. `mic.m4a`에 내 목소리만, `system.m4a`에 상대 목소리가 들어갔는가
5. 두 파일 길이 차이가 1초 이내인가
6. VoiceType 자신의 소리(알림음 등)가 `system.m4a`에 안 들어갔는가

- [ ] **Step 4: 장시간 — 90분 연속**

1. F5로 녹음 시작 후 90분간 방치(회의 중이면 더 좋다)
2. 중간에 화면을 끄지 말고 두었을 때 **디스플레이가 안 꺼지는가** (전원 어서션 동작 확인)
3. 종료 후 `session.json`의 `discontinuities`가 몇 건인가
4. 두 트랙 길이 차이가 **1초 이내**인가 → 초 단위를 넘으면 스펙 14절 4번에 따라 드리프트 대책을 재검토한다
5. 활성 상태 보기에서 녹음 중 CPU·메모리를 확인한다

- [ ] **Step 5: 강제 종료 복구**

Task 13 Step 4와 동일한 절차를 릴리스 빌드로 반복한다.

- [ ] **Step 6: 결과를 스펙에 반영한다**

90분 실측에서 트랙 길이 차이·CPU·불연속 건수를 스펙 14절 "수용한 한계"에 실측값으로 기록하고 커밋한다.

```bash
git add docs/superpowers/specs/2026-08-12-meeting-recorder-design.md
git commit -m "docs(recorder): 90분 실측 결과를 스펙에 반영"
```

---

## 완료 조건

- [ ] `swift test` 전부 통과 (기존 32 + 신규 약 20)
- [ ] `swift build` 경고 0
- [ ] 화면 기록 권한 없이 F5 → 마이크 녹음 동작
- [ ] 화면 기록 권한 있고 회의 중 → 2트랙 분리 녹음 동작
- [ ] 강제 종료 후 재실행 → 복구 동작
- [ ] 90분 연속 녹음에서 트랙 길이 차이 1초 이내

## 다음 계획

`docs/superpowers/plans/`에 별도로 작성한다:

1. **전사 파이프라인** — `STTBatchEngine` 프로토콜, `SonioxBatchClient`(원격 파일 삭제 포함), `TranscriptSegment`, `TranscriptMerger`(누설 중복 제거), `RecordingMarkdown`, `transcript.md` 생성
2. **설정 UI** — '녹음' 탭(저장 폴더·전사 엔진·핫키·예상 화자 수·누설 제거 토글·시스템 오디오 범위 안내)
3. **`DeepgramBatchClient`** — 대체 전사 경로
