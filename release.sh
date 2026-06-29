#!/bin/bash
# VoiceType 릴리스 빌드 + Sparkle appcast 생성
# 사용: ./release.sh 1.0.1
set -e
cd "$(dirname "$0")"

VER="${1:?버전을 지정하세요 (예: ./release.sh 1.0.1)}"
DIST="dist"

echo "▶ 버전 $VER 빌드…"
# Info.plist 버전 갱신
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" Info.plist 2>/dev/null || true

./build_app.sh release

echo "▶ 공증(notarize)… (credentials 'voicetype-notary' 필요. 없으면 수동)"
# 사전 1회: xcrun notarytool store-credentials voicetype-notary --apple-id ... --team-id XAJGN9YVP2 --password <app-specific>
mkdir -p "$DIST"
ZIP="$DIST/VoiceType-$VER.zip"
ditto -c -k --keepParent VoiceType.app "$ZIP"
if xcrun notarytool submit "$ZIP" --keychain-profile voicetype-notary --wait 2>/dev/null; then
    xcrun stapler staple VoiceType.app
    rm -f "$ZIP"; ditto -c -k --keepParent VoiceType.app "$ZIP"
    echo "  공증 + staple 완료"
else
    echo "  ⚠️ 공증 건너뜀(credentials 없음). 배포 전 수동 공증 필요."
fi

echo "▶ Sparkle appcast 생성 (Keychain의 EdDSA 개인키로 서명)…"
GA="$(find .build -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -n "$GA" ]; then
    "$GA" "$DIST"
    echo "  $DIST/appcast.xml 생성됨"
else
    echo "  ⚠️ generate_appcast 없음 — swift build 후 재시도"
fi

echo ""
echo "✓ 릴리스 준비 완료: $DIST/"
echo "  다음: GitHub Release($VER) 생성 → $DIST/VoiceType-$VER.zip 와 $DIST/appcast.xml 업로드"
echo "  (SUFeedURL이 releases/latest/download/appcast.xml 이므로 appcast.xml은 매 릴리스 에셋으로)"
