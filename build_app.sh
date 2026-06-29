#!/bin/bash
# VoiceType.app 번들 생성 (메뉴바 받아쓰기 앱)
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="VoiceType.app"

echo "▶ swift build ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/VoiceType"
[ -f "$BIN" ] || { echo "빌드 산출물 없음: $BIN"; exit 1; }

echo "▶ 번들 구성…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/VoiceType"
cp Info.plist "$APP/Contents/Info.plist"

# SwiftPM 리소스 번들의 현지화 파일을 앱 메인 번들로 복사한다.
# String(localized:)는 기본적으로 Bundle.main을 조회하므로 이 단계가 빠지면
# 화면에 "mic.section" 같은 키가 그대로 노출된다.
RESOURCE_BUNDLE="$(find .build -path "*$CONFIG/VoiceType_VoiceType.bundle" -type d 2>/dev/null | head -1)"
if [ -n "$RESOURCE_BUNDLE" ]; then
    echo "▶ 현지화 리소스 포함…"
    for LPROJ in "$RESOURCE_BUNDLE"/*.lproj; do
        [ -d "$LPROJ" ] || continue
        ditto "$LPROJ" "$APP/Contents/Resources/$(basename "$LPROJ")"
    done
fi

# Sparkle.framework 번들 포함 (자동 업데이트)
FW="$(find .build -path "*$CONFIG/Sparkle.framework" -type d 2>/dev/null | head -1)"
if [ -n "$FW" ]; then
    echo "▶ Sparkle.framework 포함…"
    cp -R "$FW" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VoiceType" 2>/dev/null || true
fi

echo "▶ 코드사인 (Developer ID — 재빌드 시 서명 일관 → Keychain 재인증 안 뜸)…"
SIGN_ID="Developer ID Application: Gyujeong Park (XAJGN9YVP2)"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    SIGN="$SIGN_ID"
else
    echo "  (Developer ID 없음 → adhoc 폴백)"
    SIGN="-"
fi
# nested code 안쪽부터 서명: 바이너리→XPC/앱→프레임워크 순서
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    # 1) 모든 실행 바이너리 (Autoupdate 등) 먼저 서명
    find "$APP/Contents/Frameworks/Sparkle.framework" -type f -perm +111 ! -name "*.h" ! -name "*.plist" \
        -print0 2>/dev/null \
        | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN" {} 2>/dev/null || true
    # 2) XPC 번들 및 내부 .app
    find "$APP/Contents/Frameworks/Sparkle.framework" -type d \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null \
        | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN" {} 2>/dev/null || true
    # 3) 프레임워크 전체
    codesign --force --options runtime --timestamp --sign "$SIGN" \
        "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
fi
codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"

echo "✓ 완료: $(pwd)/$APP"

# 설치: ./build_app.sh release install  → /Applications에 안전하게 교체
# (주의: `cp -R src /Applications/VoiceType.app`은 대상이 있으면 그 안으로 중첩 복사되어
#  옛 바이너리가 계속 실행되는 함정이 있다. 반드시 rm -rf 후 ditto 로 교체한다.)
if [ "$2" = "install" ] || [ "$1" = "install" ]; then
    DEST="/Applications/VoiceType.app"
    echo "▶ 설치 중 ($DEST)…"
    pkill -x VoiceType 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    # 중첩 재발 방지 검증
    if [ -e "$DEST/VoiceType.app" ]; then
        echo "❌ 중첩 복사 감지 — 설치 중단"; exit 1
    fi
    echo "✓ 설치 완료 — 실행: open '$DEST'"
    open "$DEST"
else
    echo "  실행: open '$APP'   (또는 ./build_app.sh release install 로 /Applications 교체)"
fi
echo "  권한: 시스템 설정 > 개인정보 보호 > 마이크 / 손쉬운 사용(Accessibility) 에서 VoiceType 허용"
