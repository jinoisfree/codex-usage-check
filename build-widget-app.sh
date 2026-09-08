#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_ROOT="/private/tmp/codex-usage-widget-build"
SCRATCH_PATH="$BUILD_ROOT/swift-build"
BUILD_OUTPUT="$SCRATCH_PATH/arm64-apple-macosx/release"
APP_BUNDLE="$SCRIPT_DIR/AppBundle/Codex Usage.app"
EXTENSION_BUNDLE="$APP_BUNDLE/Contents/PlugIns/CodexUsageWidgetExtension.appex"
EXTENSION_CONTENTS="$EXTENSION_BUNDLE/Contents"
HOST_ENTITLEMENTS="$SCRIPT_DIR/AppBundle/CodexUsage.entitlements"
WIDGET_ENTITLEMENTS="$SCRIPT_DIR/WidgetExtension/CodexUsageWidget.entitlements"

SWIFT_MODULECACHE_PATH="$BUILD_ROOT/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swiftpm-cache" \
swift build \
    -c release \
    --scratch-path "$SCRATCH_PATH" \
    --package-path "$SCRIPT_DIR"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$EXTENSION_CONTENTS/MacOS"
cp "$BUILD_OUTPUT/CodexUsageMenuBar" "$APP_BUNDLE/Contents/MacOS/CodexUsageMenuBar"
cp "$BUILD_OUTPUT/CodexUsageWidgetExtension" "$EXTENSION_CONTENTS/MacOS/CodexUsageWidgetExtension"
cp "$SCRIPT_DIR/WidgetExtension/Info.plist" "$EXTENSION_CONTENTS/Info.plist"

codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$EXTENSION_BUNDLE"
codesign --force --sign - --entitlements "$HOST_ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep "$APP_BUNDLE"

print "Built: $APP_BUNDLE"
print "Widget extension: $EXTENSION_BUNDLE"
