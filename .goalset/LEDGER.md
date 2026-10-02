# LEDGER — VoiceType 디버그·사용성 개선

append-only 진행 로그. 모듈 완료·파킹·막힘·방향 전환마다 1줄 이상. 형식: `- YYYY-MM-DD HH:MM [Mx] 무엇을 · 증거(명령·출력 요약·커밋)`
재개 시 이 파일 마지막 20줄부터 읽는다.

- 2026-10-03 04:44 [hook] ARM session=8360337a budget=10.0h
- 2026-10-03 04:46 [M1] finishTimeout 결과 도착 시 취소 + handleFinal 세션토큰 가드, Soniox/Deepgram/KeyTester URLSession invalidate, KeyTester Soniox 무음+finalize로 정상키 오판 방지, Deepgram 401 판별 · scripts/gs_check.sh M1 PASS (빌드+49테스트)
- 2026-10-03 04:47 [M2] 프리셋 폐기모델 교체(deepseek-v4-flash/openai/gpt-oss-20b/gemini-3.1-flash-lite/google/gemini-3.1-flash-lite), 로드 시 자동 이관, DeepSeek만 thinking 비활성, 기본 LLM=Gemini, PostProcessOutcome로 실패 사유 알림(onNotice) · gs_check M2 PASS, 53 tests
- 2026-10-03 04:49 [M3] ToastController(비차단 상단 HUD, 길이비례 표시시간, 클릭 닫기) 신설, notify()→토스트, 권한·키 누락만 UserActionNeeded→버튼 달린 창(runModal 1곳), 접근성은 시스템 프롬프트+토스트, --render-toast 헤드리스 렌더 · gs_check M3 PASS, toast_warning.png 육안 확인
