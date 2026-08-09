#!/usr/bin/env bash
# Build SwiftASR.app bundle from SPM sources + Resources/Models
#
# 用法：
#   ./scripts/build_app.sh [version] [build-number]
#
# 输出：
#   build/SwiftASR.app                  (可双击运行 / 装到 /Applications)
#   build/SwiftASR.app.dSYM             (debug symbols,跟 .app 同目录)
#
# 设计要点：
# - 走 SPM `swift build -c release`,不依赖 Xcode
# - Apple Silicon only (arm64);Intel Mac 朋友需要改 `swift build --arch x86_64`
# - 只复制 ModelCatalog 声明的生产模型，不打包历史实验目录
# - ad-hoc 签名 (codesign --sign -),朋友首次运行要走"右键→打开"绕过 Gatekeeper
# - 想正式分发需要 Apple Developer ID ($99/年) + notarytool 公证,改 codesign 命令
set -euo pipefail

# ── 参数与版本管理 ───────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${SWIFTASR_VERSION:-0.1.0}}"
BUILD_NUMBER="${2:-${SWIFTASR_BUILD_NUMBER:-1}}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "ERROR: invalid version '$VERSION'"
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: build number must be a positive integer"
    exit 1
fi

BUILD_DIR="$ROOT_DIR/build"
APP_NAME="SwiftASR"
DISPLAY_NAME="SwiftASR"
BUNDLE_ID="${BUNDLE_ID:-io.github.bigboyq.SwiftASR}"
MIN_OS="14.0"

echo "==> Building $DISPLAY_NAME v$VERSION (build $BUILD_NUMBER)"
echo "    Bundle ID: $BUNDLE_ID"
echo "    Signing:   $SIGNING_IDENTITY"
echo

# ── 1. Swift release 编译 (arm64 only) ─────────────────────────
cd "$ROOT_DIR"
echo "==> [1/5] swift build -c release"
swift build -c release
BINARY_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    # 兼容路径
    BINARY_PATH="$ROOT_DIR/.build/release/$APP_NAME"
fi
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: 找不到 release 二进制"
    exit 1
fi
echo "    Binary: $BINARY_PATH"

# ── 2. 创建 .app bundle 结构 ──────────────────────────────────────
echo "==> [2/5] Creating .app bundle"
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP" "$APP.dSYM"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY_PATH" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# dSYM (debug symbols) 跟 .app 一起
if [ -d "$BINARY_PATH.dSYM" ]; then
    cp -R "$BINARY_PATH.dSYM" "$APP.dSYM"
    echo "    dSYM: $APP.dSYM"
fi

# ── 3. 拷生产模型与许可证进 .app ────────────────────────────────
echo "==> [3/5] Copying Resources/Models"
# 与 ModelCatalog 的开发期环境变量同名。发布包仍只复制固定模型集，不提供
# 用户可选路径；环境变量仅供构建机准备模型时覆盖默认资源目录。
MODELS_SRC="${SWIFTASR_DEV_MODELS_ROOT:-$ROOT_DIR/Resources/Models}"
if [ ! -d "$MODELS_SRC" ]; then
    echo "ERROR: $MODELS_SRC 不存在,先准备好模型"
    exit 1
fi
# 用应用本身的 ModelCatalog 校验完整文件清单，加载、健康检查和打包不再各维护一份。
"$BINARY_PATH" --validate-models "$MODELS_SRC"
echo "==> Verifying fixed production model hashes"
(
    cd "$MODELS_SRC"
    shasum -a 256 -c "$ROOT_DIR/MODEL_ARTIFACTS.sha256"
)
mkdir -p "$APP/Contents/Resources/Models/vad"
mkdir -p "$APP/Contents/Resources/Models/seaco_paraformer"
mkdir -p "$APP/Contents/Resources/Models/punc"
mkdir -p "$APP/Contents/Resources/Models/speaker"

rsync -a \
    "$MODELS_SRC/vad/model_quant.onnx" \
    "$MODELS_SRC/vad/am.mvn" \
    "$APP/Contents/Resources/Models/vad/"
rsync -a \
    "$MODELS_SRC/seaco_paraformer/model_quant.onnx" \
    "$MODELS_SRC/seaco_paraformer/model_eb_quant.onnx" \
    "$MODELS_SRC/seaco_paraformer/tokens.json" \
    "$MODELS_SRC/seaco_paraformer/am.mvn" \
    "$APP/Contents/Resources/Models/seaco_paraformer/"
rsync -a \
    "$MODELS_SRC/punc/model_quant.onnx" \
    "$MODELS_SRC/punc/tokens.json" \
    "$APP/Contents/Resources/Models/punc/"
rsync -a \
    "$MODELS_SRC/speaker/model_batch16.mlmodelc" \
    "$APP/Contents/Resources/Models/speaker/"

for notice in LICENSE NOTICE MODEL_LICENSES.md MODEL_ARTIFACTS.sha256 THIRD_PARTY_NOTICES.md ACKNOWLEDGEMENTS.md; do
    cp "$ROOT_DIR/$notice" "$APP/Contents/Resources/$notice"
done
echo "    Models: $(du -sh "$APP/Contents/Resources/Models" | awk '{print $1}')"
echo "    Files:  $(find "$APP/Contents/Resources/Models" -type f | wc -l | awk '{print $1}')"

# AppIcon (有就拷)
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "    Icon:   $APP/Contents/Resources/AppIcon.icns"
fi

# ── 4. Info.plist ────────────────────────────────────────────────
echo "==> [4/5] Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
EOF

# ── 5. Ad-hoc 签名 ──────────────────────────────────────────────
echo "==> [5/5] codesign --sign $SIGNING_IDENTITY"
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'
codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "✓ Done: $APP"
echo "  Open with: open '$APP'"
echo "  Install:   cp -R '$APP' /Applications/"
