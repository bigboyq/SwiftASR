#!/usr/bin/env bash
# Build and verify one local SwiftASR release artifact.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${SWIFTASR_VERSION:-0.1.0}}"
BUILD_NUMBER="${2:-${SWIFTASR_BUILD_NUMBER:-1}}"

cd "$ROOT_DIR"

echo "==> Running lightweight tests"
swift test --filter SwiftASRTests

echo "==> Building application"
"$ROOT_DIR/scripts/build_app.sh" "$VERSION" "$BUILD_NUMBER"

echo "==> Building disk image"
"$ROOT_DIR/scripts/build_dmg.sh"

DMG="$ROOT_DIR/build/SwiftASR-$VERSION-$BUILD_NUMBER.dmg"
if [ ! -f "$DMG" ]; then
    echo "ERROR: expected release artifact not found: $DMG"
    exit 1
fi

echo "==> Verifying application and disk image"
codesign --verify --deep --strict --verbose=2 "$ROOT_DIR/build/SwiftASR.app"
hdiutil verify "$DMG"
spctl --assess --type execute --verbose=2 "$ROOT_DIR/build/SwiftASR.app" || {
    if [ "${SIGNING_IDENTITY:--}" = "-" ]; then
        echo "NOTE: Gatekeeper rejection is expected for an ad-hoc, unnotarized build."
    else
        echo "ERROR: Gatekeeper assessment failed for a distribution-signed build."
        exit 1
    fi
}

CHECKSUM="$DMG.sha256"
(
    cd "$(dirname "$DMG")"
    shasum -a 256 "$(basename "$DMG")"
) > "$CHECKSUM"

echo "==> Release ready"
ls -lh "$DMG" "$CHECKSUM"
cat "$CHECKSUM"
