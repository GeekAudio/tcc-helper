#!/bin/sh
# 生成 AppIcon.icns —— 由 tools/make-icon.swift 画底图，再拆成 iconset 交给 iconutil
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/make-icon"
SRC="$ROOT/tools/make-icon.swift"
OUT="$ROOT/Resources/AppIcon.icns"

SDK="$(xcrun --show-sdk-path)"
mkdir -p "$ROOT/bin"

# 源码比二进制新才重编
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  echo "== 编译 make-icon =="
  swiftc -swift-version 5 -sdk "$SDK" -O -framework AppKit -o "$BIN" "$SRC"
fi

TMP="$(mktemp -d /tmp/tccicon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "== 画 1024 底图 =="
"$BIN" "$TMP/icon-1024.png"

gen() { sips -z "$1" "$1" "$TMP/icon-1024.png" --out "$ICONSET/$2" >/dev/null 2>&1; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "== 合成 icns =="
iconutil -c icns "$ICONSET" -o "$OUT"
ls -la "$OUT"
