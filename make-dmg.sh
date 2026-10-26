#!/bin/sh
# make-dmg.sh —— 打包成 DMG（标准「拖进 Applications」安装盘）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="TCC Helper"                 # 卷名（挂载后显示的名字，可以带空格）
FILEBASE="TCC-Helper"             # 文件名用连字符：GitHub 上传资源时会把空格转成点
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 1.0)"
OUT="$ROOT/$FILEBASE-$VERSION.dmg"

echo "== 1) 构建 App =="
sh "$ROOT/build.sh"

echo "== 2) 构建 CLI =="
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$ROOT/bin"
CLI_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tcc-cli.XXXXXX")"
trap 'rm -rf "$CLI_BUILD"' EXIT
for ARCH in x86_64 arm64; do
  swiftc -swift-version 5 -target "$ARCH-apple-macos13.0" -sdk "$SDK" -O -framework AppKit \
    -o "$CLI_BUILD/tcchelper-cli-$ARCH" \
    "$ROOT/Sources/TCCCore.swift" "$ROOT/Sources/TCCAuto.swift" \
    "$ROOT/Sources/ComputerUse.swift" "$ROOT/CLI/main.swift"
done
lipo -create "$CLI_BUILD/tcchelper-cli-x86_64" "$CLI_BUILD/tcchelper-cli-arm64" -output "$ROOT/bin/tcchelper-cli"
codesign --force --sign - "$ROOT/bin/tcchelper-cli"
codesign --verify --strict "$ROOT/bin/tcchelper-cli"
rm -rf "$CLI_BUILD"

echo "== 3) 摆盘面 =="
STAGE="$(mktemp -d /tmp/tccdmg.XXXXXX)"
trap 'rm -rf "$STAGE" "$CLI_BUILD"' EXIT
ditto --norsrc --noextattr "$ROOT/TCC Helper.app" "$STAGE/TCC Helper.app"
ln -s /Applications "$STAGE/Applications"      # 拖拽目标
cp "$ROOT/README.md" "$STAGE/README.md"
ditto --norsrc --noextattr "$ROOT/bin/tcchelper-cli" "$STAGE/tcchelper-cli"
ls -la "$STAGE" | sed 's/^/   /'

echo "== 4) 生成 DMG =="
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null

echo "== 5) 校验：挂载看一眼 =="
MP="$(hdiutil attach "$OUT" -nobrowse -readonly | sed -n 's|.*\(/Volumes/.*\)|\1|p' | head -1)"
test -n "$MP"
trap 'hdiutil detach "$MP" >/dev/null 2>&1 || true; rm -rf "$STAGE" "$CLI_BUILD"' EXIT
echo "   挂载点：$MP"
ls -la "$MP" | sed 's/^/   /'
if [ -d "$MP/TCC Helper.app" ] && [ -L "$MP/Applications" ]; then
  echo "   ✔ 结构正确（App + Applications 软链）"
else
  echo "   ✘ 结构异常"
  exit 1
fi
codesign --verify --deep --strict "$MP/TCC Helper.app"
codesign --verify --strict "$MP/tcchelper-cli"
lipo -archs "$MP/TCC Helper.app/Contents/MacOS/TCCHelper"
lipo -archs "$MP/tcchelper-cli"
hdiutil detach "$MP" >/dev/null
trap 'rm -rf "$STAGE" "$CLI_BUILD"' EXIT
echo "   已卸载"

echo
echo "== 完成 =="
ls -lh "$OUT" | sed 's/^/   /'
echo "   SHA-256:"
shasum -a 256 "$OUT" | awk '{print "     "$1}'
