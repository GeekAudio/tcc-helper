#!/bin/sh
# 构建 TCC Helper.app —— 无需 Xcode 工程，直接 swiftc 出 bundle
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/TCC Helper.app"
BIN="TCCHelper"

echo "== 清理旧产物 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --show-sdk-path)"
echo "== 编译 Intel / Apple Silicon（SDK: $SDK）=="
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tcc-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
for ARCH in x86_64 arm64; do
swiftc \
  -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -sdk "$SDK" \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -o "$BUILD_DIR/$BIN-$ARCH" \
  "$ROOT/Sources/TCCCore.swift" \
  "$ROOT/Sources/TCCAuto.swift" \
  "$ROOT/Sources/ComputerUse.swift" \
  "$ROOT/Sources/ComputerUseView.swift" \
  "$ROOT/Sources/L10n.swift" \
  "$ROOT/Sources/TCCHelperApp.swift" \
  "$ROOT/Sources/AdvancedView.swift"
done
lipo -create "$BUILD_DIR/$BIN-x86_64" "$BUILD_DIR/$BIN-arm64" -output "$APP/Contents/MacOS/$BIN"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 图标：没有就现生成（tools/make-icns.sh 会画图 + iconutil 合成）
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "== 生成图标 =="
  sh "$ROOT/tools/make-icns.sh" >/dev/null
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "== ad-hoc 签名 =="
# ★ 项目目录在 Documents 下，可能被 iCloud/FileProvider 同步，
#   目录上会带 com.apple.FinderInfo、com.apple.fileprovider.fpfs#P 这类属性，
#   codesign 见到直接拒绝：resource fork, Finder information, or similar detritus not allowed
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "签名失败"; exit 1;
}
codesign -dv "$APP" 2>&1 | sed -n '1,4p'
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/$BIN"

echo
echo "== 完成 =="
echo "  $APP"
echo "  运行：open \"$APP\""
