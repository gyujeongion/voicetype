status: active

# VoiceType 녹음기 모드 — 설계 문서 (v2)

작성일: 2026-08-12
개정일: 2026-08-13 (council 교차검증 + 용도 명확화 반영)
대상 저장소: `/Users/groovyroom/Development/260620_VoiceType`

> v1 대비 변경: 마이크를 ScreenCaptureKit 밖으로 빼면서 macOS 15 게이트를 제거했고, 크래시로 파일이 깨지는 문제·음향 누설·장시간 장애 모드를 반영했다. v1의 "공유 시계라 정렬이 공짜" 주장과 "크래시해도 m4a 복구 가능" 주장은 둘 다 틀렸으므로 폐기한다.

---

## 1. 목적

F5 키로 시작·종료하는 녹음 모드를 추가한다. 두 가지 상황을 **하나의 키, 하나의 동작**으로 커버한다.

**시나리오 A — 즉석 녹음 (기본)**
맥북만 들고 있는 상황에서 F5를 누르면 내장 마이크로 즉시 녹음이 시작된다. 아이폰 음성 메모처럼 아무 준비 없이 눌러서 바로 되는 것이 요구사항이다. 권한 대화상자나 모드 선택으로 첫 녹음을 놓치면 실패다.

**시나리오 B — 온라인 회의**
Zoom·Discord·Google Meet으로 회의할 때는 내 목소리(마이크)와 상대 목소리(컴퓨터 내부 소리)가 **둘 다** 녹음되어야 한다. 두 소리는 서로 섞이지 않고 별개 트랙으로 남는다.

B는 A의 확장이다. 사용자가 모드를 고르지 않는다. 시스템 오디오는 가능하면 얹히고, 안 되면 마이크만으로 계속 간다.

### 성공 기준

1. F5 → 즉시 녹음 시작. 화면 기록 권한이 없어도 마이크 녹음은 반드시 된다.
2. 회의 중이면 시스템 오디오가 별도 트랙으로 추가된다.
3. 종료 후 화자 라벨이 붙은 마크다운 전사문이 생성된다.
4. 앱이 강제 종료돼도 그 시점까지 녹음된 오디오는 **재생·전사 가능한 상태로** 남는다.

### 비목표

- LLM 회의 요약 — 전사문 md가 나오면 외부 도구로 처리 가능. 후속 검토.
- 실시간 전사 표시 — 배치 전사로 확정.
- 화자 실명 매핑 UI — "상대 1/2"까지만.
- 음향 반향 제거(AEC) DSP — 아래 12절 참조. 텍스트 레벨 완화로 갈음한다.

---

## 2. 확정 사실

### 2.1 SDK 실측 (2026-08-13, Xcode SDK 헤더 직접 확인)

`ScreenCaptureKit.framework/Headers/SCStream.h` 기준:

| 심볼 | 최소 버전 | 위치 |
|---|---|---|
| `capturesAudio` | **macOS 13.0** | SCStream.h:295 |
| `sampleRate` / `channelCount` | macOS 13.0 | SCStream.h:300,305 |
| `excludesCurrentProcessAudio` | macOS 13.0 | SCStream.h:310 |
| `synchronizationClock` | macOS 13.0 | SCStream.h:453 |
| `SCStreamOutputTypeAudio` | macOS 13.0 | SCStream.h:30 |
| `SCStreamOutputTypeMicrophone` | macOS 15.0 | SCStream.h:31 |
| `captureMicrophone` | macOS 15.0 | SCStream.h:360 |
| `microphoneCaptureDeviceID` | macOS 15.0 | SCStream.h:365 |

**결론**: 마이크를 SCStream으로 잡지 않으면 macOS 15가 전혀 필요 없다. 앱의 배포 타겟 macOS 14를 그대로 유지한다.

### 2.2 현재 앱 서명 상태 (실측)

- Hardened Runtime **켜져 있음** (`flags=0x10000(runtime)`)
- entitlements **비어 있음** (App Sandbox 없음)
- `NSMicrophoneUsageDescription` Info.plist에 **있음**
- 이 상태로 마이크 받아쓰기가 실제 동작 중 — 마이크 접근에 별도 entitlement가 필요하지 않음이 경험적으로 확인됨

ScreenCaptureKit 추가 후 이 전제가 유지되는지는 구현 단계에서 재확인한다.

### 2.3 전사 엔진

| 항목 | Soniox (기본) | Deepgram (대체) |
|---|---|---|
| 배치 엔드포인트 | `POST https://api.soniox.com/v1/transcriptions` | prerecorded API |
| 화자분리 | `enable_speaker_diarization`, 추가 과금 없음 | `diarize_model=latest` (`diarize=true`는 deprecated) |
| 가격 | $0.10/시간 | nova-3 단일언어 $0.0077/분 |
| 한국어 | 지원 | nova-3 `ko` 지원 |

90분 회의 2트랙(= 오디오 180분) 기준 Soniox 약 **$0.30**. 두 키 모두 Keychain에 존재한다(`soniox_api_key`, `deepgram_api_key`).

**불확실 — 구현 중 실측 필요**
- Soniox async 응답의 word/token 타임스탬프·speaker 필드 정확한 스키마
- Deepgram 화자분리가 기본 요금에 포함인지 별도 과금인지 (문서 간 불일치. Soniox가 기본이라 블로커 아님)

---

## 3. 아키텍처

### 3.1 2레이어 캡처

```
F5
 │
 ├─ 레이어 1 (항상, 즉시)  AudioCapture (AVAudioEngine)
 │     기존 코드 재사용. 마이크 우선순위 설정 그대로 적용.
 │     화면 권한 불필요. macOS 14. 시작 지연 밀리초.
 │     → mic.caf
 │
 └─ 레이어 2 (되면 붙음)   SCStream
       capturesAudio = true
       captureMicrophone = false          ← 마이크는 레이어 1 담당
       excludesCurrentProcessAudio = true
       화면 기록 권한 필요. 없으면 이 레이어만 건너뜀.
       → system.caf
```

레이어 2가 실패해도 **레이어 1은 절대 중단되지 않는다.** 시스템 오디오 실패는 경고일 뿐 녹음 실패가 아니다. `session.json`과 전사문 상단에 "시스템 오디오 미포함"을 명시한다.

### 3.2 컴포넌트

```
AppDelegate
   └─ RecorderController        (@MainActor, F5 처리·상태 머신·복구)
        ├─ MicTrackRecorder     (AudioCapture 래핑 → mic.caf)
        ├─ SystemTrackRecorder  (SCStream → system.caf)
        ├─ RecordingTranscriber (배치 전사 오케스트레이션)
        │     └─ STTBatchEngine (프로토콜)
        │          ├─ SonioxBatchClient    (기본)
        │          └─ DeepgramBatchClient  (대체)
        └─ RecordingStore       (회차 폴더·manifest·목록)

VoiceTypeCore (순수 로직, 시스템 의존 없음 → 유닛 테스트)
   ├─ RecordingSession      (회차 메타데이터 모델)
   ├─ TranscriptSegment     (트랙·화자·시작·끝·텍스트)
   ├─ TimelineMap           (PTS 불연속 구간 매핑)
   ├─ TranscriptMerger      (2트랙 → 시간순 단일 시퀀스 + 누설 중복 제거)
   └─ RecordingMarkdown     (세그먼트 → md 렌더)
```

`VoiceTypeCore`에는 시스템 API를 쓰지 않는 순수 함수·모델만 넣는다. 병합·중복제거·md 렌더러가 여기 있으므로 캡처와 네트워크 없이 테스트된다.

### 3.3 상태 머신

`RecorderController.State`:

```
idle → starting → recording → stopping → transcribing → idle
                                   ↓            ↓
                                 (실패)      (실패: 오디오 보존)
                                   ↓            ↓
                                 idle         idle
```

- `starting`/`stopping` 중 F5 → 무시 (debounce)
- `transcribing` 중 F5 → **새 녹음 시작 허용**. 전사는 백그라운드로 계속된다.
- 녹음 중에는 F8/F7 받아쓰기와 스페이스바 트리거를 차단하고 안내한다 (마이크 점유).

---

## 4. 시간축 — v1의 오류 수정

> **v1의 틀린 전제**: "두 버퍼가 같은 스트림 시계를 쓰므로 정렬이 구조적으로 공짜다."
> 이는 두 검토 패널 모두에게 반박당했다. `synchronizationClock`은 비교 가능한 시간 영역만 보장할 뿐, 버퍼 누락·슬립·장치 재연결로 생긴 **중간 공백**을 없애주지 않는다. 변환한 샘플을 단순 연속 기록하면 PTS 공백이 압축되어, 첫 오프셋 보정만으로는 이후 구간이 어긋난다.

### 4.1 공통 시간축

두 레이어가 서로 다른 캡처 경로를 쓰므로 **host time을 공통 축**으로 삼는다.

- 레이어 1: `AVAudioPCMBuffer` tap의 `AVAudioTime.hostTime`
- 레이어 2: `CMSampleBuffer.presentationTimeStamp` (`synchronizationClock` = host clock 기반)

세션 시작 시 `mach_absolute_time()`을 `t0`로 잡고, 모든 버퍼를 `t0` 기준 상대 초로 환산한다.

### 4.2 불연속 처리

각 트랙에서 **버퍼마다 예상 PTS와 실제 PTS를 대조**한다. 샘플 수로 계산한 예상 시각과 실제 도착 시각의 차이가 임계값(기본 100ms)을 넘으면 불연속으로 판정하고:

1. 파일에는 그 간격만큼 **무음을 삽입**한다 (파일 시간축 = 실제 경과 시간 유지)
2. 동시에 `TimelineMap`에 구간 레코드를 남긴다 (`{fileTime, wallTime, reason}`)

무음 삽입만으로 파일 자체가 벽시계와 일치하므로, 전사 결과 타임스탬프를 그대로 쓸 수 있다. `TimelineMap`은 진단용이자 검증용이다.

### 4.3 드리프트에 대한 판단

물리적으로 마이크 ADC와 시스템 오디오 경로의 클럭이 다르므로 장시간 미세 드리프트는 남는다. 다만 이 설계에서 실질 위험은 낮다고 판단한다.

- 우리는 오디오를 **믹싱하지 않는다**. 전사문을 초 단위 블록으로 병합할 뿐이다.
- 90분에 수백 ms 수준의 드리프트는 발화 블록 순서를 바꾸지 않는다.
- 초 단위 이상의 어긋남은 드리프트가 아니라 4.2의 불연속에서 오며, 그건 무음 삽입으로 처리된다.

따라서 리샘플링 기반 정밀 동기화는 도입하지 않는다. 대신 검증 단계에서 90분 실측으로 실제 어긋남을 측정하고, 초 단위를 넘으면 그때 재검토한다.

---

## 5. 컨테이너 — v1의 오류 수정

> **v1의 틀린 전제**: "크래시해도 m4a 파일이 디스크에 있으니 복구할 수 있다."
> `AVAssetWriter`는 `moov` atom(프레임 인덱스)을 `finishWriting()` 시점에 파일 끝에 쓴다. 기본 `movieFragmentInterval`은 무효값이라 조각 기록이 꺼져 있다. 89분째 프로세스가 죽으면 `mdat`만 남아 **AVFoundation·Soniox·Deepgram 어느 것도 읽지 못한다.** v1의 크래시 복구 조항은 성립 불가였다.

### 5.1 채택안: 녹음 중 CAF(LPCM) → 정상 종료 시 m4a

- **녹음 중**: 16kHz mono 16-bit LPCM을 Core Audio Format(`.caf`)으로 기록한다. 헤더 확정이 필요 없어 **마지막으로 쓰인 바이트까지 항상 유효**하다. 크래시 복구가 비로소 성립한다.
- **정상 종료 시**: `.caf` → 16kHz mono AAC `.m4a`로 트랜스코딩하고 `.caf`를 삭제한다.

용량: 녹음 중 트랙당 약 115MB/시간(일시적), 종료 후 약 14MB/시간(영구). 기존 받아쓰기 원본 저장이 이미 16kHz mono m4a라 형식이 일관된다.

**수용한 대가**: 16kHz mono로 고정하므로 원음 충실도는 영구히 버린다. 회의 음성 용도에는 충분하다고 판단했다. 원음 보관이 필요해지면 캡처 포맷만 native로 바꾸면 되고 나머지 설계는 그대로다.

### 5.2 대안 (기각)

- *조각형 MP4* (`movieFragmentInterval = 10초`): 크래시 시 마지막 완성 조각까지 살릴 수 있지만, 마지막 10초를 잃고 구현이 CAF보다 복잡하다.
- *native format 무손실 보관*: 용량이 3배 이상이고 회의 용도에 이점이 없다.

---

## 6. 전사

### 6.1 트랙별 개별 호출

| 트랙 | 화자분리 | 라벨 |
|---|---|---|
| `mic.m4a` | **OFF** | 전부 `나` |
| `system.m4a` | **ON** | `상대 1`, `상대 2`, … |

**v1에서 밝힌 기각 사유는 틀렸다.** v1은 Deepgram multichannel을 "채널마다 화자 번호가 0부터 채번되어 병합 시 손상된다"는 이유로 기각했는데, `(channel, speaker)` 튜플로 키를 잡으면 아무 손상도 없다. 지적을 수용한다.

그럼에도 트랙별 개별 호출을 유지하는 이유는 **다르다**:
1. 마이크 트랙은 화자가 항상 한 명이므로 화자분리를 아예 끌 수 있다 — 오분리 위험과 비용이 함께 준다.
2. 한 트랙 전사가 실패해도 나머지를 독립적으로 재시도할 수 있다.
3. 시스템 트랙이 아예 없는 경우(시나리오 A)가 기본값이므로, 단일 트랙 경로가 어차피 필요하다.

비용은 두 트랙 합산 = 오디오 길이의 2배로 과금된다(90분 회의 → 180분). Soniox 기준 약 $0.30.

### 6.2 화자 ID 취급

엔진이 준 원본 speaker ID와 raw 응답을 **그대로 보존**한다(`session.json`에 저장). 재번호는 **표시 시점에만** 적용한다.

- 시스템 트랙 화자를 **첫 등장 순서대로** `상대 1`, `상대 2`로 재번호한다. 엔진이 speaker 2, 0, 1 순으로 주더라도 먼저 말한 사람이 `상대 1`이 된다.
- 화자분리 결과가 없거나 실패하면 전부 `상대`로 단일화한다.

`expectedSpeakers` 설정은 재번호에 관여하지 않는다. 전사 요청 시 엔진에 힌트로만 전달하며, 0이면 힌트를 보내지 않는다. 기본값 0.

---

## 7. 병합과 음향 누설 완화

### 7.1 음향 누설 (수용한 한계)

헤드폰 없이 스피커로 회의하면 마이크가 상대 목소리를 재수집한다. `excludesCurrentProcessAudio`는 **디지털 경로만** 차단하므로 물리적 누설에는 무력하다. 결과적으로 같은 발화가 `mic` 트랙에서는 `나`로, `system` 트랙에서는 `상대 N`으로 중복 기록될 수 있다.

**사용자가 이 오염을 명시적으로 수용했다.** 헤드폰 착용을 제품 제약으로 걸지 않는다. AEC DSP도 도입하지 않는다. 대신 아래의 값싼 완화만 넣는다.

### 7.2 텍스트 레벨 중복 제거

병합 시, 마이크 세그먼트가 시스템 세그먼트와 **① 시간이 겹치고 ② 텍스트 유사도가 임계값 이상**이면 마이크 쪽을 버린다.

- 시간 겹침: 두 구간의 교집합이 짧은 쪽 길이의 50% 이상
- 텍스트 유사도: 정규화(공백·문장부호 제거) 후 문자 단위 유사도 0.75 이상
- 시스템 트랙을 남기는 이유: 원격 참가자의 원음이 스피커 재수집본보다 깨끗하다

기본 ON, 설정에서 끌 수 있다. 순수 함수이므로 유닛 테스트 대상이다.

### 7.3 겹쳐 말하기

동시 발언을 단순 시작 시각 정렬로 직렬화하면 두 발언이 잘못 뒤섞인다. 세그먼트는 시작·끝을 모두 가진 **구간 모델**로 두고, 구간이 실제로 겹칠 때는 시작 시각 기준으로 안정 정렬하되 md에 겹침 표시를 남긴다.

### 7.4 출력 형식

```markdown
# 녹음 2026-08-13 14:30

- 길이: 1시간 12분 11초
- 트랙: 마이크 + 시스템 오디오
- 참여: 나, 상대 1, 상대 2
- 전사: Soniox (2026-08-13 15:44 생성)

---

**[00:00:03] 나**

안녕하세요, 시작하겠습니다.

**[00:00:09] 상대 1**

네 반갑습니다. 자료 공유드릴게요.
```

시스템 트랙이 없으면 `- 트랙: 마이크만 (시스템 오디오 미포함)`으로 표기한다. 화자가 바뀔 때마다 새 블록. 같은 화자가 이어 말하면 한 블록으로 합치되 발화 간격이 2.0초를 넘으면 나눈다.

### 7.5 저장 레이아웃

```
<설정된 루트>/                       기본값 ~/Documents/VoiceType Recordings/
   260813_143005_a1b2/
       session.json
       mic.m4a
       system.m4a          (시스템 오디오 없으면 생성 안 됨)
       transcript.md
```

폴더명은 `YYMMDD_HHMMSS_<4자리 랜덤>`. v1의 분 단위 이름은 충돌 가능성이 있어 초와 랜덤 접미사를 더했다. 현지화하지 않는다.

기존 받아쓰기 히스토리(`~/Library/Application Support/VoiceType/`)와 **분리한다.** 히스토리는 300건 초과 시 자동 삭제되므로 녹음이 휩쓸려 날아갈 수 있다. 녹음 파일에는 자동 삭제를 적용하지 않는다.

### 7.6 manifest

```json
{
  "id": "260813_143005_a1b2",
  "startedAt": "2026-08-13T14:30:05+09:00",
  "durationSeconds": 4331.2,
  "capture": {
    "status": "done",
    "mic":    { "file": "mic.m4a",    "discontinuities": 0 },
    "system": { "file": "system.m4a", "discontinuities": 2, "note": "sleep_gap" }
  },
  "transcription": {
    "status": "pending",
    "engine": "soniox",
    "error": null,
    "rawResponsePath": "raw/"
  }
}
```

`capture.status`와 `transcription.status`를 **분리한다.** 캡처는 끝났지만 전사가 실패한 상태를 표현해야 하기 때문이다. 갱신은 임시 파일 작성 후 원자적 교체로 한다.

---

## 8. 에러 처리와 장시간 장애 모드

### 8.1 시작 시

| 상황 | 처리 |
|---|---|
| 저장 폴더 쓰기 불가 | 녹음 시작 전 검사. 실패 시 시작하지 않고 안내 |
| 디스크 여유 부족 | 시작 전 검사(최소 2GB) + 녹음 중 주기 감시. 임계 이하로 떨어지면 정상 종료 절차로 전환 |
| 마이크 권한 없음 | 기존 받아쓰기와 동일 안내 |
| 화면 기록 권한 없음 | **녹음은 그대로 시작.** 시스템 오디오만 생략하고 1회 안내 + 시스템 설정 딥링크 |

### 8.2 녹음 중

| 상황 | 처리 |
|---|---|
| 디스플레이/시스템 슬립 | `IOPMAssertionCreateWithName`으로 `kIOPMAssertionTypePreventUserIdleDisplaySleep` 어서션 획득. 종료 시 해제 |
| 화면 잠금 | SCStream 샘플 전달이 멈출 수 있음. 공백을 4.2로 처리하고 재개를 감시 |
| 외부 디스플레이 분리 | `SCContentFilter` 무효화 가능. `SCStreamDelegate` 오류를 받아 시스템 트랙만 종료하고 마이크는 계속 |
| 입력 장치 분리·블루투스 전환 | 포맷 변경 감지 → 컨버터 재생성. 실패 시 해당 구간을 불연속으로 기록하고 계속 |
| 사용자가 macOS 공유 표시에서 직접 중단 | `userStopped` 오류 수신 → 시스템 트랙만 정리, 마이크 계속 |
| writer 백프레셔 | 캡처 콜백에서 변환·파일 I/O를 하지 않는다. **크기 제한 큐로 넘기고** 전용 직렬 큐에서 처리. 큐가 가득 차면 드롭을 카운트해 manifest에 기록 |
| 앱 크래시·강제 종료 | `.caf`는 마지막 바이트까지 유효. 다음 실행 시 `capture.status != done`인 세션을 감지해 복구 제안 |

SCK는 `userStopped`·`systemStoppedStream`·`failedToStartMicrophoneCapture` 등을 따로 던지며 **자동 복구를 하지 않는다.** 각각을 명시적으로 처리한다.

### 8.3 종료·전사

| 상황 | 처리 |
|---|---|
| 정상 종료 순서 | 캡처 중단 → 콜백 drain → writer 마감 → 파일 검증 → CAF→m4a 트랜스코딩 → manifest 확정 |
| 전사 API 실패 | **원본을 절대 먼저 삭제하지 않는다.** `status: failed` + 에러 기록. 설정에서 재시도 |
| 한 트랙만 실패 | 성공한 트랙만으로 md 생성 + 실패 표기. 실패 트랙만 재시도 가능 |
| 트랙이 무음 | 전사 결과가 비면 해당 트랙을 건너뛰고 나머지로 md 생성. 상단에 경고 표기 |

### 8.4 시스템 오디오 범위의 한계 (안내 필요)

ScreenCaptureKit의 오디오 필터는 **창 단위가 아니라 앱 단위**다. 디스플레이 전체를 대상으로 하면 회의 소리뿐 아니라 알림음·음악·다른 브라우저 탭 소리까지 들어간다. Chrome의 Meet 창 하나를 지정해도 다른 Chrome 탭 오디오가 포함될 수 있다.

이번 범위에서는 **디스플레이 전체 오디오를 캡처**한다(자기 자신만 제외). 사용자가 원하는 것이 "컴퓨터에서 나는 소리" 전체이므로 이 편이 요구에 맞고 단순하다. 다만 설정 화면에 위 한계를 명시한다. 회의 앱 선택 기능은 후속 과제로 둔다.

---

## 9. 프라이버시

- **Soniox async는 업로드한 파일을 자동 삭제하지 않는다.** 전사 결과 수신 후 원격 파일을 명시적으로 삭제한다. 실패 시 재시도하고, 그래도 실패하면 사용자에게 알린다.
- API 키는 기존과 동일하게 Keychain에만 둔다. 코드·번들에 넣지 않는다.
- 녹음 중임을 항상 보이게 한다(메뉴바 아이콘 + 인디케이터 + 경과 시간). 사용자가 녹음 중임을 모르는 상태가 없어야 한다.
- 녹음 동의는 사용자 책임이지만, 첫 사용 시 안내를 1회 표시한다.

---

## 10. UI

- **메뉴바**: 녹음 중 아이콘 변경 + 경과 시간
- **인디케이터**: 기존 `RecordingIndicator` 재사용. 경과 시간 캡션과 **트랙별 VU 미터 2개**(마이크/시스템)를 표시한다. 라우팅·권한 실패로 90분 무음을 녹음하는 사고를 막는 유일한 수단이다.
- **설정 '녹음' 탭**: 저장 폴더, 전사 엔진, 핫키, 예상 화자 수, 누설 중복 제거 on/off, 시스템 오디오 범위 한계 안내
- **전사 완료**: 알림 + Finder로 폴더 열기

---

## 11. 통합 지점 (기존 코드 수정 목록)

| 파일 | 변경 |
|---|---|
| `Info.plist` | `NSScreenCaptureUsageDescription` 추가. 문구에 "오디오만 사용하며 화면은 녹화하지 않습니다" 명시 |
| `AppDelegate.swift:216` `registerProfileHotkeys()` | 녹음 핫키를 **예약 id `9000`**으로 추가 등록. 프로파일은 배열 인덱스를 id로 쓰므로 충돌 없음 |
| `AppDelegate.swift:166` `setupHotkey()` | `onTrigger`에서 예약 id면 `recorder.toggle()`로 분기 |
| `AppDelegate.swift:93` `updateIcon()` | 녹음 상태 아이콘 분기 |
| `DictationController.swift` | `trigger()` 진입부에서 녹음 중이면 차단 + 안내 |
| `AudioCapture.swift` | CAF(LPCM) 기록 경로 추가. 기존 m4a 경로는 받아쓰기용으로 유지 |
| `AppSettings.swift` | `recordingHotkeyKeyCode`(기본 96=F5)·`recordingHotkeyModifiers`·`recordingFolderPath`·`recordingSTTProvider`·`expectedSpeakers`·`dedupeBleed` 추가. **관대한 디코딩 필수** — 기존 settings.json에 없는 필드다 |
| `SettingsView.swift` | '녹음' 탭 신설 |
| `Localizable.strings` (ko/en) | 문자열 추가 |
| `RecordingIndicator.swift` | 경과 시간 + 2트랙 VU 미터 지원 |

---

## 12. 테스트 전략

### 유닛 테스트 (`VoiceTypeCore`)

1. **`TranscriptMerger`**
   - 두 트랙 세그먼트의 시간순 인터리브
   - 화자 재번호: 엔진이 speaker 2, 0, 1 순으로 줘도 먼저 말한 사람이 `상대 1`
   - 화자분리 결과가 없으면 전부 `상대`로 단일화
   - 한쪽 트랙이 비었을 때 나머지만으로 정상 동작
   - 겹치는 발화의 안정 정렬
2. **누설 중복 제거**
   - 시간 겹침 + 텍스트 유사 → 마이크 쪽 제거
   - 시간은 겹치지만 텍스트가 다름 → **둘 다 유지** (동시 발언이므로)
   - 텍스트는 같지만 시간이 멀다 → 둘 다 유지 (실제로 같은 말을 반복한 경우)
   - 임계값 경계값
3. **`RecordingMarkdown`**
   - 같은 화자 연속 발화 병합, 2.0초 초과 시 분리
   - 타임스탬프 포맷 (`00:00:03`, 1시간 초과 시 `01:12:11`)
   - 시스템 트랙 없을 때 헤더 표기
4. **`TimelineMap`** — 불연속 구간 기록·조회
5. **`RecordingSession` 코덱** — 필드 누락 구버전 JSON의 관대한 디코딩
6. **STT 응답 파서** — 실제 응답을 픽스처로 저장해 네트워크 없이 검증

### CLI 검증 모드

기존 `--transcribe-file`·`--preview-indicator` 패턴을 따른다.

- `--record-audio <초>` — GUI 없이 2레이어 캡처만 실측. 트랙별 길이·불연속 수 출력
- `--transcribe-recording <폴더>` — 기존 녹음 폴더로 전사·병합·md 생성만 재실행

### 수동 검증 (IÖN)

캡처와 권한은 GUI·TCC가 걸려 자동화 불가.

1. 화면 기록 권한 **거부** 상태에서 F5 → 마이크 녹음이 정상 시작되는가 (시나리오 A의 핵심)
2. 권한 허용 후 Google Meet 통화 → 상대 목소리가 `system`에, 내 목소리가 `mic`에 들어가는가
3. VoiceType 자신의 소리가 시스템 트랙에 안 들어가는가
4. **90분 연속 녹음** — 두 트랙 길이 차이, 슬립·화면잠금 후 재개, 실제 CPU·메모리
5. 녹음 중 강제 종료 → 재실행 시 복구 제안이 뜨고 `.caf`가 전사 가능한가
6. 스피커로 회의 시 누설 중복 제거가 실제로 동작하는가

---

## 13. 구현 순서

각 단계는 그 자체로 검증 가능해야 한다.

1. **코어 모델·순수 로직** — `RecordingSession`, `TranscriptSegment`, `TimelineMap`, `TranscriptMerger`(누설 제거 포함), `RecordingMarkdown` + 유닛 테스트. 캡처·네트워크 없이 완결.
2. **`RecordingStore`** — 회차 폴더, manifest 원자적 입출력, 미완료 세션 스캔.
3. **`MicTrackRecorder`** — `AudioCapture`에 CAF 경로 추가. `--record-audio`로 실측. **이 시점에 시나리오 A가 완성된다.**
4. **`SystemTrackRecorder`** — SCStream 시스템 오디오. 권한 거부 시 우아한 생략 검증. **시나리오 B 완성.**
5. **`STTBatchEngine` + `SonioxBatchClient`** — 실제 API 왕복으로 스키마 확정, 픽스처 저장, 원격 파일 삭제 포함.
6. **`RecorderController`** — 상태 머신, 전원 어서션, 복구, 디스크 감시.
7. **`AppDelegate` 통합** — F5, 아이콘, 인디케이터·VU, 받아쓰기 차단.
8. **설정 UI + 현지화**
9. **`DeepgramBatchClient`** — 대체 경로. 1~8 동작 후 추가.

3단계가 끝나면 이미 "아이폰 음성 메모처럼 F5로 즉시 녹음"이 동작한다. 4단계 이후가 회의 기능이다. 중간에 멈춰도 쓸모 있는 상태로 남는 순서다.

---

## 14. 수용한 한계 (문서에 명시할 것)

1. **음향 누설** — 스피커 사용 시 마이크가 상대 목소리를 재수집한다. 텍스트 레벨 중복 제거로 완화하되 완벽하지 않다. 사용자가 수용했다.
2. **시스템 오디오 범위** — 알림음·음악 등 다른 앱 소리가 함께 녹음된다. **사용자가 감안 가능하다고 확인했다(2026-08-13).** 회의 앱만 선별하는 기능은 만들지 않는다. 설정 화면에 이 동작을 한 줄로 안내하는 것으로 끝낸다.
3. **16kHz mono 고정** — 원음 충실도를 버린다. 음성 전사 용도에 최적화.
4. **드리프트** — 90분에 수백 ms 수준의 트랙 간 어긋남이 남을 수 있다. 전사문 병합 단위가 초이므로 무해하다고 판단했으나, 90분 실측에서 초 단위를 넘으면 재검토한다.

---

## 15. v1에서 폐기된 결정 (재도입 금지)

| v1 결정 | 폐기 사유 |
|---|---|
| macOS 15 게이트 + `captureMicrophone` | 마이크를 SCStream 밖으로 빼면 불필요. SDK 실측으로 `capturesAudio`가 macOS 13임을 확인 |
| "공유 스트림 시계 → 정렬 공짜" | 틀림. PTS 공백은 시계 공유와 무관하게 발생 |
| "크래시해도 m4a 복구 가능" | 틀림. `moov` atom이 없어 파싱 불가 |
| Deepgram multichannel 기각 사유("채널별 독립 채번으로 손상") | 틀린 근거. `(channel, speaker)` 튜플로 해결됨. 트랙별 전사는 **다른** 이유로 유지 |
| "엔진 speaker ID를 노출하지 않는다" | 부정확. 원본 ID는 보존하고 표시할 때만 재번호 |
| 회차 폴더명 `YYMMDD_HHMM` | 분 단위라 충돌 가능. 초 + 랜덤 접미사로 변경 |
