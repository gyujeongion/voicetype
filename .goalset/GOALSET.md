# GOALSET — VoiceType 디버그·사용성 개선

> 생성 2026-10-03 · 정본 설계 문서. 세션이 끊기거나 컴팩트돼도 이 파일 + MODULES + DECISIONS + LEDGER만 읽으면 이어갈 수 있어야 한다.

## 1. 원문 목적 (사용자 발화 그대로 — 수정 금지)

> /goalset 전체적으로 디버그하고 사용성 개선할거 찾아서 개선해.

(대상: 직전 대화에서 다루던 `VoiceType 저장소 루트` — macOS 메뉴바 받아쓰기 앱. 사용자는 이 앱을 매일 실사용 중: history 300건 꽉 참, 최근 기록 2026-10-02.)

## 2. 최종 목표 상태 (North Star)

- 코드 정독으로 확인된 실제 버그(아래 §5 B1~B13)가 전부 수정돼 있고, 각 수정은 빌드·유닛테스트·헤드리스 CLI 검증 중 하나 이상으로 증거가 남아 있다.
- F8 받아쓰기: LLM 후처리가 15초를 넘겨도 가짜 "STT 지연" 에러가 안 뜨고, 늦게 끝난 옛 세션이 새 세션을 죽이지 않는다. 후처리가 실패하면 사용자가 그 사실을 알 수 있다.
- F5 녹음: 단축키·저장 폴더를 설정에서 바꿀 수 있고, 녹음 중 입력 장치가 바뀌어도(에어팟 분리 등) 마이크 트랙이 끊기지 않는다. 히스토리에서 앱 안에서 바로 재생·검색·안전 삭제(휴지통)가 된다.
- 알림이 성공 안내까지 모달 창으로 막지 않는다(비차단 토스트). 조치가 필요한 권한 오류만 버튼 달린 창.
- 새 빌드가 /Applications에 설치돼 실행되고, 기존 사용자 설정(settings.json·키체인 키·히스토리)이 그대로 유지된다.

## 3. 범위

- 포함: Sources/ 전 영역 버그 수정, 설정·히스토리·메뉴바 사용성 개선, 폐기된 LLM 프리셋 모델 교체, 깨진 STT 프리셋 정리, 유닛테스트 보강, 로컬 설치·실물 확인.
- 제외 (하지 않는 것): GitHub 푸시·Release 발행·Sparkle 배포(D-01: 사용자가 "설치까지" 선택), 앱스토어 대응, 새 STT 엔진 추가, 디자인 전면 개편, 실시간 전사 오버레이 같은 대형 신기능.
- 건드리면 안 되는 것: `~/Library/Application Support/VoiceType/settings.json`·`history.json`·`Recordings/`(사용자 데이터 — 삭제·초기화 금지), 키체인 `com.ion.voicetype` 항목, 서명 인증서 지문(build_app.sh SIGN_ID), Info.plist의 SUPublicEDKey·SUFeedURL, 기존 F5 녹음 폴더(`~/Documents/VoiceType Recordings`).

## 4. 사전 확정 결정 (킥오프 인터뷰 결과)

| # | 결정 | 확정 내용 | 근거/사용자 발화 |
|---|------|-----------|------------------|
| D-01 | 마감 범위 | 새 브랜치 `fix/debug-usability-pass` 커밋 + /Applications 설치·스크린샷 확인까지. 푸시·릴리스는 보고 후 별도 결정 | 사용자 선택 "설치까지 (추천)" |
| B-1 | 폐기 모델 교체 (기본값 적용) | DeepSeek `deepseek-chat`→`deepseek-v4-flash` + `thinking:{type:disabled}`, Groq `llama-3.1-8b-instant`→`openai/gpt-oss-20b`, Gemini `gemini-2.5-flash-lite`→`gemini-3.1-flash-lite`(사용자 실사용 모델). 기존 설정의 폐기 모델명도 로드 시 자동 이관 | 웹 확인: deepseek-chat 2026-07-24 폐기, llama-3.1-8b-instant 2026-08-16 폐기, gemini-2.5-flash-lite 2026-10-16 종료 |
| B-2 | 알림 방식 (기본값 적용) | 비차단 토스트(화면 상단 HUD). 권한 등 조치 필요한 오류만 "시스템 설정 열기" 버튼 달린 창 | 업계 표준, 되돌리기 쉬움 |
| B-3 | 삭제 방식 (기본값 적용) | F5 녹음·히스토리 삭제는 확인창 + F5 폴더는 휴지통 이동(영구삭제 아님) | 안전 기본값 |
| B-4 | STT 커스텀 프리셋 (기본값 적용) | Soniox 프로토콜로는 절대 동작 안 하는 Gladia·AssemblyAI·Speechmatics·Rev.ai·Symbl 프리셋 제거, "Custom (Soniox 호환)"만 유지 | 코드상 custom=SonioxClient |
| B-5 | Esc 취소 (기본값 적용) | F8 받아쓰기 녹음 중에만 Esc를 임시 전역 단축키로 잡아 취소(붙여넣기 안 함). 녹음 아닐 땐 Esc 안 건드림 | 오작동 시 쓰레기 텍스트 붙여넣기 방지 |
| B-6 | 클립보드 복원 동작 | 현행 유지(자동 붙여넣기 후 기존 클립보드 복원) | 사용자 미언급, 현행 의도적 설계 |
| B-7 | 에어팟 자동 우선 | 현행 유지 | 사용자가 과거 직접 요청한 기능 |

## 5. 아키텍처 · 모듈 분해

확인된 버그 (코드 정독, 2026-10-03):
- B1 `DictationController.finish()`의 15초 finishTimeout이 STT 결과 도착 후에도 살아있음 → LLM(30초 타임아웃) 처리 중 가짜 "STT 지연" 에러 + 상태 idle 전환 → 그 사이 새 세션 시작 시 옛 handleFinal Task가 cleanup()/setState(.idle)로 새 세션을 죽임.
- B2 `SettingsViewModel.persist()`가 `$0 = settings`로 통째 덮어써 LocalizationManager가 바꾼 appLanguage를 옛 값으로 되돌림.
- B3 LLM 프리셋 기본 모델 3종 폐기(§4 B-1). `LLMConfig` 기본값도 deepseek-chat → 신규 설치 시 후처리 100% 실패.
- B4 `PostProcessRunner` 실패(키 없음·401·404·타임아웃)가 무음 → "영어 번역" 프로파일이 한국어 원문을 그대로 붙여넣어도 모름.
- B5 STT 커스텀 프리셋 5종이 Soniox 프로토콜로 접속 → 동작 불가.
- B6 F5 녹음 단축키·저장 폴더 설정 UI 없음(에러 메시지는 "설정에서 다른 폴더를 지정하세요"라고 안내). recordingFolderPath는 앱 시작 때만 반영.
- B7 단축키 충돌(프로파일끼리·F5와) 미검출, RegisterEventHotKey 실패 무시.
- B8 녹음 중 입력 장치 변경(AVAudioEngineConfigurationChange) 미처리 → 엔진 정지, F5 마이크 트랙 조용히 끊김.
- B9 Soniox/Deepgram 클라이언트가 세션마다 URLSession 생성 후 invalidate 안 함(누수).
- B10 F5 녹음 폴더 영구삭제·히스토리 전체삭제가 확인 없이 즉시 실행.
- B11 모든 알림이 NSAlert.runModal — 성공 안내("녹음이 저장됐습니다")까지 매번 모달.
- B12 메뉴 "받아쓰기 시작/중지"가 꾹누르기 프로파일이면 중지 불가, 메뉴에 F5 없음.
- B13 온보딩 창 ✕로 닫으면 Dock 아이콘 잔류 + 다음 실행에 온보딩 재등장.

```
M1 F8 세션 안정성(B1,B9) ─┐
M2 LLM 프리셋·후처리 결과(B3,B4) ─┤
M3 토스트 알림(B11) ─────────┼─> M8 메뉴바·Esc취소(B12) ─┐
M4 설정 동기화·단축키 충돌(B2,B7) ─> M5 F5 설정 UI(B6) ──┤
M6 히스토리 재생·검색·안전삭제(B10) ───────────────┤
M7 오디오 장치 변경 복구(B8) ─────────────────────┤
M9 STT 프리셋·온보딩 정리(B5,B13) ─────────────────┴─> M10 설치·실물 확인
```

인터페이스 계약:
- 토스트: `ToastController.shared.show(_ message:, kind:)` (AppDelegate.notify가 내부적으로 분기). 액션 필요 오류는 `notifyActionable(message:, settingsURL:)`.
- 후처리 결과: `PostProcessRunner.run(...) -> PostProcessOutcome { text, failure: String? }`.
- 단축키 충돌: VoiceTypeCore `HotkeyConflicts.conflict(...)` 순수 함수(테스트 대상).
- 히스토리 검색: VoiceTypeCore `HistoryFilter.matches(_:query:)` 순수 함수.
- LLM 모델 이관: VoiceTypeCore `LLMPresets.migratedModel(endpoint:model:)` 순수 함수.

검증 도구: `scripts/gs_check.sh <모듈ID>` — swift build + swift test + 모듈별 단언(테스트 필터·CLI 자기검증·코드 구조 확인). exit 0 = 통과.

## 6. Goal 계층

| 층 | 내용 | 판정 방법 |
|----|------|-----------|
| North Star | §2 | M10 + LEDGER 증거 |
| 마일스톤 | ①핵심 버그(M1·M2·M4·M7) ②사용성(M3·M5·M6·M8·M9) ③설치·실물 확인(M10) | MODULES 상태 |
| 모듈 goal | MODULES.md 참조 | `goalset.py status --run` |
| 세션 훅 | `goalset.py arm` — COMPLETE 또는 DONE_EXCEPT_PARKED+HANDOFF 전까지 종료 차단 | stop_hook.py |

## 7. 자율 권한 (사전 합의)

- AI가 알아서 해도 되는 것: 코드 수정, 유닛테스트·CLI 검증 모드 추가, 로컬 커밋(브랜치 fix/debug-usability-pass), release 빌드·서명, /Applications 설치·재실행, 스크린샷 확인.
- 항상 멈추고 물어야 하는 것: git push, GitHub Release, 공증·appcast 배포, 사용자 데이터(settings/history/Recordings) 삭제·초기화 → 발생 시 파킹, 절대 실행 안 함.
- 예산: 시간 10h / 외부 API 호출은 사용자 키로 하는 소량 검증만.

## 8. 리스크 · 가정

| 리스크/가정 | 틀렸을 때 영향 | 조기 검증 방법 |
|-------------|----------------|----------------|
| settings.json 관대한 디코딩이 새 필드 추가에도 기존 값 보존 | 사용자 프로파일·단어사전 유실 | M10 설치 전후 settings.json 핵심 필드 diff |
| AVAudioEngine 설정변경 후 재시작이 같은 인스턴스에서 동작 | F5 마이크 트랙 복구 실패 | M7 CLI에서 알림 강제 발송 후 기록 지속 확인 |
| 토스트 NSPanel이 다른 앱 포커스 상태에서도 보임 | 알림 놓침 | 인디케이터와 같은 패널 설정(hidesOnDeactivate=false) 재사용 + 헤드리스 렌더 |
| 새 Gemini/DeepSeek/Groq 모델명이 실제 존재 | 프리셋 선택 시 404 | 웹 확인 완료(§4 B-1). Gemini는 사용자 실사용 모델 |
| 실사용 앱 교체 설치 | 작업 중 받아쓰기 일시 중단 | 마지막 단계에만 1회 설치 |
