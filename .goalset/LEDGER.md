# LEDGER — VoiceType 디버그·사용성 개선

append-only 진행 로그. 모듈 완료·파킹·막힘·방향 전환마다 1줄 이상. 형식: `- YYYY-MM-DD HH:MM [Mx] 무엇을 · 증거(명령·출력 요약·커밋)`
재개 시 이 파일 마지막 20줄부터 읽는다.

- 2026-10-03 04:44 [hook] ARM session=8360337a budget=10.0h
- 2026-10-03 04:46 [M1] finishTimeout 결과 도착 시 취소 + handleFinal 세션토큰 가드, Soniox/Deepgram/KeyTester URLSession invalidate, KeyTester Soniox 무음+finalize로 정상키 오판 방지, Deepgram 401 판별 · scripts/gs_check.sh M1 PASS (빌드+49테스트)
- 2026-10-03 04:47 [M2] 프리셋 폐기모델 교체(deepseek-v4-flash/openai/gpt-oss-20b/gemini-3.1-flash-lite/google/gemini-3.1-flash-lite), 로드 시 자동 이관, DeepSeek만 thinking 비활성, 기본 LLM=Gemini, PostProcessOutcome로 실패 사유 알림(onNotice) · gs_check M2 PASS, 53 tests
- 2026-10-03 04:49 [M3] ToastController(비차단 상단 HUD, 길이비례 표시시간, 클릭 닫기) 신설, notify()→토스트, 권한·키 누락만 UserActionNeeded→버튼 달린 창(runModal 1곳), 접근성은 시스템 프롬프트+토스트, --render-toast 헤드리스 렌더 · gs_check M3 PASS, toast_warning.png 육안 확인
- 2026-10-03 04:51 [M4] persist()가 appLanguage를 SettingsStore 현재값으로 보존(언어 되돌아감 수정), HotkeyRules(타자키·Esc 단독 거부, 프로파일·F5 중복 검출)+9테스트, HotkeyManager 등록 실패 id 보고→프로파일 카드 경고, 임시 단축키(Esc용) API · gs_check M4 PASS
- 2026-10-03 04:53 [M5] 설정>일반에 'F5 회의 녹음' 섹션: 단축키 캡처(HotkeyRules 검사·등록실패 경고), 저장폴더 열기/변경/기본값(쓰기권한 확인), applyRecordingFolder로 재시작 없이 즉시 반영, 에러 문구를 실제 UI 경로로 · gs_check M5 PASS (화면 확인은 M10)
- 2026-10-03 04:55 [M6] 히스토리: 앱 내 재생/정지(AudioPreviewPlayer, F8·F5 공통), 검색창(HistoryFilter: 최종본·원문·프로파일 AND 검색 +3테스트), 전체삭제 확인창, F5 녹음은 확인창+휴지통 이동(실패 시 아무것도 안 지움), 복사됨 표시 1.5초 후 복귀, 탭 닫으면 재생 정지 · gs_check M6 PASS
- 2026-10-03 04:58 [M7] AudioCapture가 AVAudioEngineConfigurationChange 시 장치 재선택+tap/컨버터 재구성 재시작(0.3초 모음), F5 마이크·F8 받아쓰기 연결, 재연결/끊김 토스트 · --selftest-device-change 4: 재연결 1회, 파일 3.97초/4.0, 뒤1/4 유효샘플 78% SELFTEST_PASS
- 2026-10-03 04:58 [pause] 사용자 요청으로 일시정지. 남은 모듈 M8·M9·M10. 재개: GS arm 후 M8부터
- 2026-10-03 04:58 [hook] DISARM (manual)
- 2026-10-03 21:16 [hook] ARM session=8360337a budget=8.0h
- 2026-10-03 21:16 [resume] 사용자 '마저해' — M8부터 재개, 재arm
- 2026-10-03 21:17 [M8] 메뉴바 동적 재구성(NSMenuDelegate): 프로파일별 받아쓰기+단축키 표기, 녹음 중엔 종료/취소, F5 시작/종료·폴더 열기, 마지막 결과 복사; dictation.stop()/cancel() 추가(꾹누르기 프로파일도 메뉴로 종료), 녹음·처리 중에만 Esc 임시 핫키로 취소(세션토큰 무효화+오디오 삭제+붙여넣기 없음) · gs_check M8 PASS (실동작은 M10 설치 후)
- 2026-10-03 21:17 [M9] 동작 불가 커스텀 프리셋 5종(Gladia·AssemblyAI·Speechmatics·Rev.ai·Symbl) 제거+Custom 안내문(Soniox 호환 명시), OnboardingController NSWindowDelegate로 ✕ 닫기 시 markDone·Dock 정책 복원, STTPresetTests 3개 · gs_check M9 PASS
- 2026-10-03 21:26 [M10] release 빌드·Developer ID 서명·/Applications 설치, 실행 중(pid 확인), settings 9개 핵심 필드 보존 OK, 설정창(일반·F5 섹션·히스토리) 스크린샷 3장 육안 확인, M1~M10 gs_check 전체 PASS, 68 tests
