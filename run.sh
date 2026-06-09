#!/bin/bash
# 빌드 후 실행. (전체 Xcode 없이 Command Line Tools만으로 동작)
set -e
cd "$(dirname "$0")"
mkdir -p build

if [ ! -f Sources/MeetingRoomBooker/Secrets.swift ]; then
  echo "❌ Secrets.swift 가 없습니다. 예시 파일을 복사해 OAuth 값을 채우세요:"
  echo "   cp Sources/MeetingRoomBooker/Secrets.swift.example Sources/MeetingRoomBooker/Secrets.swift"
  exit 1
fi

# --- CLT 깨진 modulemap 우회 (SwiftBridging 모듈 중복 정의) ---
# /Library/Developer/CommandLineTools/usr/include/swift 안에 module.modulemap 과
# bridging.modulemap 이 같은 SwiftBridging 모듈을 중복 선언 → 빌드 실패.
# 둘 다 있을 때만, module.modulemap 을 빈 파일로 보이게 하는 VFS 오버레이를 적용한다.
# (시스템 파일은 수정하지 않음 / sudo 불필요)
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

echo "🔨 빌드 중… (첫 빌드는 시스템 모듈 캐시 생성으로 몇 분 걸릴 수 있어요)"
swiftc -swift-version 5 Sources/MeetingRoomBooker/*.swift -o build/MeetingRoomBooker "${OVFLAGS[@]}"

echo "🚀 실행 — 메뉴바 우측 상단에 달력 아이콘(📅)이 나타납니다. (종료: 팝오버의 전원 버튼)"
exec ./build/MeetingRoomBooker
