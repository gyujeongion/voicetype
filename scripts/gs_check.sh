#!/bin/bash
# goalset 모듈 검증. 사용: scripts/gs_check.sh <M1..M10>
# 공통: 디버그 빌드 + 전체 유닛테스트. 그 뒤 모듈별 단언. exit 0 = 통과.
set -u
cd "$(dirname "$0")/.."
M="${1:?모듈 ID (M1..M10)}"
S=Sources/VoiceType
C=Sources/VoiceTypeCore

fail() { echo "FAIL [$M]: $*"; exit 1; }
has() { grep -q -- "$2" "$1" || fail "$1 에 '$2' 없음"; }
hasnt() { ! grep -q -- "$2" "$1" || fail "$1 에 '$2' 남아 있음"; }

if [ "$M" != "M10" ]; then
    swift build >/tmp/vt_gs_build.log 2>&1 || { tail -30 /tmp/vt_gs_build.log; fail "빌드 실패"; }
    swift test >/tmp/vt_gs_test.log 2>&1 || { grep -E "error|failed" /tmp/vt_gs_test.log | tail -20; fail "테스트 실패"; }
fi
BIN=.build/debug/VoiceType

case "$M" in
M1)
    # 결과 도착 즉시 타임아웃 취소 + 옛 세션 Task가 새 세션을 정리하지 못하게
    has $S/DictationController.swift "finishTimeout?.cancel()"
    has $S/DictationController.swift "guard self.sessionToken == token"
    # 회귀 방지(2026-10-03): 취소된 timeout Task가 `try?`로 CancellationError를 삼키고 흘러내려
    # 결과 도착 직후 가짜 'STT 응답 지연' 에러를 내던 버그
    hasnt $S/DictationController.swift 'try? await Task.sleep'
    has $S/DictationController.swift 'catch { return }'
    has $S/SonioxClient.swift "invalidateAndCancel"
    has $S/DeepgramClient.swift "invalidateAndCancel"
    ;;
M2)
    swift test --filter LLMPresetTests >/dev/null 2>&1 || fail "LLMPresetTests 실패"
    # 폐기 모델이 기본값으로 남아 있지 않아야 한다 (이관 표 안의 언급은 허용)
    hasnt $C/PostProcessor.swift 'model: String = "deepseek-chat"'
    hasnt $C/LLMPresets.swift 'defaultModel: "llama-3.1-8b-instant"'
    hasnt $C/LLMPresets.swift 'defaultModel: "deepseek-chat"'
    hasnt $C/LLMPresets.swift 'defaultModel: "gemini-2.5-flash-lite"'
    has $S/PostProcessRunner.swift "PostProcessOutcome"
    has $S/DictationController.swift "outcome.failure"
    ;;
M3)
    OUT=$(mktemp -d)
    "$BIN" --render-toast "$OUT" >/dev/null 2>&1 || fail "--render-toast 실행 실패"
    ls "$OUT"/toast_*.png >/dev/null 2>&1 || fail "토스트 렌더 PNG 없음"
    has $S/AppDelegate.swift "ToastController"
    # 정보성 알림 경로에서 runModal 금지 — runModal은 notifyActionable 한 곳에만
    [ "$(grep -c 'runModal' $S/AppDelegate.swift)" -le 1 ] || fail "AppDelegate에 runModal이 2곳 이상"
    ;;
M4)
    swift test --filter HotkeyConflictTests >/dev/null 2>&1 || fail "HotkeyConflictTests 실패"
    has $S/SettingsViewModel.swift "appLanguage"
    has $S/HotkeyManager.swift "failedIDs"
    ;;
M5)
    has $S/SettingsView.swift "recorder.section"
    has $S/SettingsViewModel.swift "chooseRecordingFolder"
    has $S/SettingsViewModel.swift "applyRecordingHotkey"
    has $S/AppDelegate.swift "applyRecordingFolder"
    ;;
M6)
    swift test --filter HistoryFilterTests >/dev/null 2>&1 || fail "HistoryFilterTests 실패"
    has $S/RecordingStore.swift "trashItem"
    has $S/SettingsView.swift "confirmationDialog"
    has $S/SettingsView.swift "AudioPreviewPlayer"
    ;;
M7)
    has $S/AudioCapture.swift "AVAudioEngineConfigurationChange"
    "$BIN" --selftest-device-change 4 >/tmp/vt_gs_m7.log 2>&1 || { tail -15 /tmp/vt_gs_m7.log; fail "장치 변경 자기검증 실패"; }
    grep -q "SELFTEST_PASS" /tmp/vt_gs_m7.log || fail "SELFTEST_PASS 없음"
    ;;
M8)
    has $S/AppDelegate.swift "cancelHotkeyID"
    has $S/DictationController.swift "func cancel()"
    has $S/AppDelegate.swift "menu.recorder.start"
    has $S/AppDelegate.swift "copyLastResult"
    ;;
M9)
    swift test --filter STTPresetTests >/dev/null 2>&1 || fail "STTPresetTests 실패"
    has $S/OnboardingView.swift "windowWillClose"
    ;;
M10)
    APP=/Applications/VoiceType.app
    [ -d "$APP" ] || fail "$APP 없음"
    codesign --verify --deep --strict "$APP" 2>/dev/null || fail "서명 검증 실패"
    pgrep -x VoiceType >/dev/null || fail "VoiceType 실행 중 아님"
    # 설치본이 이 브랜치 최신 소스로 빌드됐는지 — 번들 바이너리가 마지막 커밋보다 새로워야 한다
    BIN_T=$(stat -f %m "$APP/Contents/MacOS/VoiceType")
    SRC_T=$(git log -1 --format=%ct -- Sources)
    [ "$BIN_T" -ge "$SRC_T" ] || fail "설치본이 최신 소스보다 오래됨"
    python3 scripts/check_settings_preserved.py || fail "사용자 설정 핵심 필드 보존 실패"
    ;;
*) fail "알 수 없는 모듈" ;;
esac
echo "PASS [$M]"
