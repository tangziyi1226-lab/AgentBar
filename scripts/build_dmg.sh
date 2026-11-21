#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/AgentBar.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/AgentBar.dmg"
MODULE_CACHE="${TMPDIR:-/tmp}/agentbar-swift-module-cache"

mkdir -p "$MODULE_CACHE" "$DIST_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

echo "==> [1/4] 编译 Release 可执行文件 (AgentBar & agentbar-hook)…"
cd "$ROOT_DIR"
swift build -c release --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE"

BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"

echo "==> [2/4] 生成应用图标 AppIcon.icns…"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR" "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swift -module-cache-path "$MODULE_CACHE" "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> [3/4] 组装并签名 AgentBar.app…"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$ROOT_DIR/Resources/default-pricing.json" ]; then
  cp "$ROOT_DIR/Resources/default-pricing.json" "$APP_BUNDLE/Contents/Resources/default-pricing.json"
fi
cp "$BIN_DIR/AgentBar" "$APP_BUNDLE/Contents/MacOS/AgentBar"
cp "$BIN_DIR/agentbar-hook" "$APP_BUNDLE/Contents/MacOS/agentbar-hook"
chmod +x "$APP_BUNDLE/Contents/MacOS/AgentBar" "$APP_BUNDLE/Contents/MacOS/agentbar-hook"

codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/agentbar-hook"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> [4/4] 打包安装包 AgentBar.dmg…"
if [ -d "/Volumes/AgentBar" ]; then
  hdiutil detach "/Volumes/AgentBar" -quiet || hdiutil detach "/Volumes/AgentBar" -force -quiet || true
fi
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/AgentBar.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "AgentBar" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo ""
echo "✓ 构建完成："
echo "  App: $APP_BUNDLE"
echo "  DMG: $DMG_PATH"
