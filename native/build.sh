#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_NAME="AIUsageBar"
BUILD_DIR="$HERE/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

SOURCES=(
    "Sources/AIUsageBar/AIUsageBarApp.swift"
    "Sources/AIUsageBar/UsageModels.swift"
    "Sources/AIUsageBar/UsageReader.swift"
    "Sources/AIUsageBar/UsageStore.swift"
    "Sources/AIUsageBar/ContentView.swift"
    "Sources/AIUsageBar/ClaudeOAuth.swift"
    "Sources/AIUsageBar/ClaudeOAuthClient.swift"
    "Sources/AIUsageBar/CodexOAuth.swift"
    "Sources/AIUsageBar/CodexOAuthClient.swift"
)

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES_DIR"

echo "==> swiftc -> $MACOS/$APP_NAME"
swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -O \
    -parse-as-library \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -o "$MACOS/$APP_NAME" \
    "${SOURCES[@]}"

cp "$HERE/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "==> codesign ad-hoc"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> done: $APP_BUNDLE"
