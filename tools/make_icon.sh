#!/bin/bash
# tools/IconGen.swift 로 1024 PNG를 만들고, iconset → Resources/AppIcon.icns 생성.
set -e
cd "$(dirname "$0")/.."
mkdir -p build Resources

# CLT modulemap 중복(SwiftBridging) 우회 오버레이
SWIFTDIR="$(xcode-select -p)/usr/include/swift"
OVFLAGS=()
if [ -f "$SWIFTDIR/module.modulemap" ] && [ -f "$SWIFTDIR/bridging.modulemap" ]; then
  printf '// emptied via VFS overlay\n' > build/empty.modulemap
  cat > build/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": false, "roots": [ { "type": "file", "name": "$SWIFTDIR/module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] }
EOF
  OV="$PWD/build/overlay.yaml"
  OVFLAGS=(-vfsoverlay "$OV" -Xcc -ivfsoverlay -Xcc "$OV")
fi

echo "🎨 아이콘 렌더링…"
swiftc -swift-version 5 tools/IconGen.swift -o build/icongen "${OVFLAGS[@]}"
build/icongen build/icon_master.png

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  s2=$((s * 2))
  sips -z "$s"  "$s"  build/icon_master.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
  sips -z "$s2" "$s2" build/icon_master.png --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✅ Resources/AppIcon.icns 생성 완료"
