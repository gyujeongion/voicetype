# MODULES — VoiceType 디버그·사용성 개선

상태: TODO · DOING · DONE(검증 통과) · PARKED(결정 대기 — 추천 기본값으로 가구현 완료, 의존 모듈 진행 가능) · BLOCKED(기술적 막힘)
검증명령: 프로젝트 루트에서 실행, exit 0 = 통과. 백틱으로 감쌀 것. 없으면 `-` (그 경우 LEDGER에 증거 필수).
결정 칸: 걸린 D-xx + 가구현 위치. PARKED면 OPEN 결정 참조 필수.

| ID | 모듈 | 의존 | 상태 | 완료조건 | 검증명령 | 결정 |
|----|------|------|------|----------|----------|------|
| M1 | F8 세션 안정성 (B1·B9) | - | DONE | STT 결과 도착 즉시 finishTimeout 취소, handleFinal Task는 자기 세션 토큰일 때만 cleanup/setState, STT 클라이언트가 종료 시 URLSession invalidate | `scripts/gs_check.sh M1` | - |
| M2 | LLM 프리셋·후처리 결과 (B3·B4) | - | DONE | 폐기 모델 교체+기존 설정 자동 이관, DeepSeek 요청에만 thinking 비활성 파라미터, PostProcessRunner가 실패 사유를 반환하고 받아쓰기가 사용자에게 알림 | `scripts/gs_check.sh M2` | - |
| M3 | 비차단 토스트 알림 (B11) | - | DONE | notify()가 모달 대신 상단 토스트, 권한 오류만 설정 열기 버튼 창, 헤드리스 렌더 PNG 생성 | `scripts/gs_check.sh M3` | - |
| M4 | 설정 동기화·단축키 충돌 (B2·B7) | - | DONE | 설정 변경이 appLanguage를 되돌리지 않음, 충돌 단축키 지정 거부+안내, 등록 실패 단축키 설정창 경고 | `scripts/gs_check.sh M4` | - |
| M5 | F5 녹음 설정 UI (B6) | M4 | DONE | 일반 탭에 F5 단축키 캡처·저장 폴더 선택/기본값 복원/열기, 변경 즉시 반영 | `scripts/gs_check.sh M5` | - |
| M6 | 히스토리 재생·검색·안전삭제 (B10) | - | DONE | 앱 안 재생 버튼(F8·F5 공통), 검색창, 삭제 확인창, F5 폴더 휴지통 이동 | `scripts/gs_check.sh M6` | - |
| M7 | 입력 장치 변경 복구 (B8) | - | DONE | AVAudioEngineConfigurationChange 시 캡처 자동 재시작, CLI 자기검증에서 강제 알림 후에도 기록 지속 | `scripts/gs_check.sh M7` | - |
| M8 | 메뉴바·Esc 취소 (B12) | M3 | DONE | 메뉴에 단축키 표기·F5 항목·마지막 결과 복사·녹음 폴더 열기, 꾹누르기 프로파일도 메뉴로 중지, 녹음 중 Esc로 취소 | `scripts/gs_check.sh M8` | - |
| M9 | STT 프리셋·온보딩 정리 (B5·B13) | - | DONE | 동작 불가 커스텀 프리셋 제거, 온보딩 ✕ 닫기 시 정리 | `scripts/gs_check.sh M9` | - |
| M10 | 설치·실물 확인 | M1,M2,M3,M4,M5,M6,M7,M8,M9 | DONE | release 빌드 서명·/Applications 설치·실행 중, 설정 파일 핵심 필드 보존, 설정창 스크린샷 확인 | `scripts/gs_check.sh M10` | D-01 |
