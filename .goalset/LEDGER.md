# LEDGER — VoiceType 디버그·사용성 개선

append-only 진행 로그. 모듈 완료·파킹·막힘·방향 전환마다 1줄 이상. 형식: `- YYYY-MM-DD HH:MM [Mx] 무엇을 · 증거(명령·출력 요약·커밋)`
재개 시 이 파일 마지막 20줄부터 읽는다.

- 2026-10-03 04:44 [hook] ARM session=8360337a budget=10.0h
- 2026-10-03 04:46 [M1] finishTimeout 결과 도착 시 취소 + handleFinal 세션토큰 가드, Soniox/Deepgram/KeyTester URLSession invalidate, KeyTester Soniox 무음+finalize로 정상키 오판 방지, Deepgram 401 판별 · scripts/gs_check.sh M1 PASS (빌드+49테스트)
