#!/bin/bash
# 빌드 후 .app 번들을 만들어 ~/Applications 에 설치한다. (Xcode/sudo/Homebrew 불필요)
# 설치하면 터미널과 무관하게 메뉴바 앱으로 계속 떠 있고, 로그인 항목에 등록하면 부팅 시 자동 실행된다.
set -e
cd "$(dirname "$0")"
mkdir -p build

APP_NAME="회의실예약"
BIN_NAME="MeetingRoomBooker"
APP_DIR="$HOME/Applications/$APP_NAME.app"

if [ ! -f Sources/MeetingRoomBooker/Secrets.swift ]; then
  echo "❌ Secrets.swift 가 없습니다. 예시 파일을 복사해 OAuth 값을 채우세요:"
  echo "   cp Sources/MeetingRoomBooker/Secrets.swift.example Sources/MeetingRoomBooker/Secrets.swift"
  echo "   (clientID / clientSecret 은 본인 구글 계정으로 발급 — README 참고)"
  exit 1
fi

# --- CLT modulemap 중복(SwiftBridging) 우회 오버레이 ---
SWIFTDIR="$(xcode-select -p)/usr/include/swift"
OVFLAGS=()
if [ -f "$SWIFTDIR/module.modulemap" ] && [ -f "$SWIFTDIR/bridging.modulemap" ]; then
  printf '// emptied via VFS overlay to avoid duplicate SwiftBridging module\n' > build/empty.modulemap
  cat > build/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": false, "roots": [ { "type": "file", "name": "$SWIFTDIR/module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] }
EOF
  OV="$PWD/build/overlay.yaml"
  OVFLAGS=(-vfsoverlay "$OV" -Xcc -ivfsoverlay -Xcc "$OV")
fi

echo "🔨 빌드 중… (첫 빌드는 수 분 걸릴 수 있어요)"
swiftc -swift-version 5 -O Sources/MeetingRoomBooker/*.swift -o "build/$BIN_NAME" "${OVFLAGS[@]}"

echo "📦 .app 번들 생성: $APP_DIR"
# 실행 중인(설치본/개발본) 인스턴스 종료 후 교체 → 업데이트 시 새 버전 반영
pkill -f "$BIN_NAME" 2>/dev/null || true
sleep 1
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "build/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
# 앱 아이콘
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.lguplus.meetingroombooker</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 로컬 빌드라 코드서명이 없다 → Gatekeeper 통과를 위해 ad-hoc 서명
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "🚀 실행"
open "$APP_DIR"

cat <<DONE

✅ 설치 완료: $APP_DIR
   - 메뉴바에 아이콘이 떠 있고, 터미널을 닫아도 계속 실행됩니다.
   - 부팅 시 자동 실행하려면:
       시스템 설정 → 일반 → 로그인 항목 → '+' → '$APP_NAME' 추가
   - 업데이트하려면: git pull 후 ./install.sh 다시 실행
   - 제거: 앱 종료 후  rm -rf "$APP_DIR"
DONE
