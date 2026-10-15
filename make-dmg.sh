#!/bin/sh
# make-dmg.sh —— 打包成 DMG（标准「拖进 Applications」安装盘）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="TCC Helper"                 # 卷名（挂载后显示的名字，可以带空格）
FILEBASE="TCC-Helper"             # 文件名用连字符：GitHub 上传资源时会把空格转成点
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 1.0)"
OUT="$ROOT/$FILEBASE-$VERSION.dmg"

echo "== 1) 构建 App =="
sh "$ROOT/build.sh" | tail -3

echo "== 2) 构建 CLI =="
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$ROOT/bin"
swiftc -swift-version 5 -target x86_64-apple-macos13.0 -sdk "$SDK" -O -framework AppKit \
  -o "$ROOT/bin/tcchelper-cli" \
  "$ROOT/Sources/TCCCore.swift" "$ROOT/Sources/TCCAuto.swift" "$ROOT/CLI/main.swift"

echo "== 3) 摆盘面 =="
STAGE="$(mktemp -d /tmp/tccdmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/TCC Helper.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # 拖拽目标
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/bin/tcchelper-cli" "$STAGE/tcchelper-cli"
ls -la "$STAGE" | sed 's/^/   /'

echo "== 4) 生成 DMG =="
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null

echo "== 5) 校验：挂载看一眼 =="
MP="$(hdiutil attach "$OUT" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
echo "   挂载点：$MP"
ls -la "$MP" | sed 's/^/   /'
if [ -d "$MP/TCC Helper.app" ] && [ -L "$MP/Applications" ]; then
  echo "   ✔ 结构正确（App + Applications 软链）"
else
  echo "   ✘ 结构异常"
fi
codesign -dv "$MP/TCC Helper.app" 2>&1 | grep -E "Identifier|Signature" | sed 's/^/   /'
hdiutil detach "$MP" >/dev/null
echo "   已卸载"

echo
echo "== 完成 =="
ls -lh "$OUT" | sed 's/^/   /'
echo "   SHA-256:"
shasum -a 256 "$OUT" | awk '{print "     "$1}'
