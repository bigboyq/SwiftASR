#!/usr/bin/env bash
# Build SwiftASR.dmg from .app bundle
#
# 用法：
#   ./scripts/build_dmg.sh           # 使用 build/SwiftASR.app
#
# 输出：
#   build/SwiftASR-<version>.dmg
#
# 设计要点：
# - dmg 内布局:SwiftASR.app + /Applications 符号链接(标准 macOS 安装体验)
# - 朋友拖 .app 到 /Applications 即可
# - UDZO 压缩(只读、压缩);非 UDZO 也可以但文件更大
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="SwiftASR"

APP="$BUILD_DIR/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: $APP 不存在,先跑 ./Scripts/build_app.sh"
    exit 1
fi

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
BUILD_NUMBER=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "0")
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}-${BUILD_NUMBER}.dmg"

echo "==> Packaging $APP → $DMG_PATH"

# ── 临时 staging:拖一个 Applications 链接进去(标准 dmg 布局) ──
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
for notice in LICENSE NOTICE MODEL_LICENSES.md MODEL_ARTIFACTS.sha256 THIRD_PARTY_NOTICES.md ACKNOWLEDGEMENTS.md; do
    cp "$ROOT_DIR/$notice" "$STAGING/$notice"
done

# ── 创建 dmg ──────────────────────────────────────────────────────
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo
echo "✓ Done: $DMG_PATH"
ls -lh "$DMG_PATH"

# ── 简单校验 ────────────────────────────────────────────────────
echo
echo "Verification:"
hdiutil verify "$DMG_PATH" && echo "  ✓ dmg image OK"

# ── 关键路径提示(给朋友用) ───────────────────────────────────────
echo
echo "安装步骤："
echo "  1. 双击 $DMG_PATH"
echo "  2. 把 SwiftASR.app 拖到 Applications 文件夹"
echo "  3. ad-hoc 构建第一次启动时右键→打开"
