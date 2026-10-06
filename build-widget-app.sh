#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_ROOT="/private/tmp/codex-usage-widget-build"
SCRATCH_PATH="$BUILD_ROOT/swift-build"
BUILD_OUTPUT="$BUILD_ROOT/direct-output"
APP_TEMPLATE="$SCRIPT_DIR/AppBundle/Template"
APP_BUNDLE="$BUILD_ROOT/Codex Usage.app"
mkdir -p "$BUILD_ROOT"
# Sign outside cloud-synced Documents: file providers can re-add FinderInfo during signing.
/usr/bin/ditto --norsrc "$APP_TEMPLATE" "$APP_BUNDLE"
EXTENSION_BUNDLE="$APP_BUNDLE/Contents/PlugIns/CodexUsageWidgetExtension.appex"
EXTENSION_CONTENTS="$EXTENSION_BUNDLE/Contents"
HOST_ENTITLEMENTS="$SCRIPT_DIR/AppBundle/CodexUsage.entitlements"
WIDGET_ENTITLEMENTS="$SCRIPT_DIR/WidgetExtension/CodexUsageWidget.entitlements"

SWIFT_MODULECACHE_PATH="$BUILD_ROOT/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swiftpm-cache" \
swift build \
    -c release \
    --scratch-path "$SCRATCH_PATH" \
    --package-path "$SCRIPT_DIR" && {
        BUILD_OUTPUT="$(swift build \
            -c release \
            --show-bin-path \
            --scratch-path "$SCRATCH_PATH" \
            --package-path "$SCRIPT_DIR")"
    } || {
        print "SwiftPM is unavailable; falling back to direct swiftc compilation."
        MODULE_CACHE="$BUILD_ROOT/direct-module-cache"
        mkdir -p "$BUILD_OUTPUT" "$MODULE_CACHE"

        SDK_ROOT=""
        SWIFT_SERIES="$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
        for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk; do
            SWIFT_INTERFACE="$candidate/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
            if grep -q "Apple Swift version $SWIFT_SERIES" "$SWIFT_INTERFACE" 2>/dev/null; then
                SDK_ROOT="$candidate"
                break
            fi
        done
        if [[ -z "$SDK_ROOT" ]]; then
            print -u2 "No SDK compatible with the active Swift compiler was found."
            exit 1
        fi

        swiftc -O -sdk "$SDK_ROOT" -module-cache-path "$MODULE_CACHE" \
            -parse-as-library -emit-library -static -emit-module \
            -module-name CodexUsageCore \
            "$SCRIPT_DIR/Sources/CodexUsageCore/AppServerUsageProvider.swift" \
            "$SCRIPT_DIR/Sources/CodexUsageCore/UsageProvider.swift" \
            "$SCRIPT_DIR/Sources/CodexUsageCore/UsageSnapshot.swift" \
            "$SCRIPT_DIR/Sources/CodexUsageCore/ServiceUsage.swift" \
            -emit-module-path "$BUILD_OUTPUT/CodexUsageCore.swiftmodule" \
            -o "$BUILD_OUTPUT/libCodexUsageCore.a"

        swiftc -O -parse-as-library -sdk "$SDK_ROOT" -module-cache-path "$MODULE_CACHE" \
            -I "$BUILD_OUTPUT" -L "$BUILD_OUTPUT" -lCodexUsageCore \
            "$SCRIPT_DIR/Sources/CodexUsageMenuBar/main.swift" \
            -o "$BUILD_OUTPUT/CodexUsageMenuBar"

        swiftc -O -parse-as-library -application-extension \
            -sdk "$SDK_ROOT" -module-cache-path "$MODULE_CACHE" \
            -I "$BUILD_OUTPUT" -L "$BUILD_OUTPUT" -lCodexUsageCore \
            "$SCRIPT_DIR/WidgetExtension/CodexUsageWidget.swift" \
            -Xlinker -e -Xlinker _NSExtensionMain \
            -o "$BUILD_OUTPUT/CodexUsageWidgetExtension"
    }

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$EXTENSION_CONTENTS/MacOS"
cp "$BUILD_OUTPUT/CodexUsageMenuBar" "$APP_BUNDLE/Contents/MacOS/CodexUsageMenuBar"
cp "$BUILD_OUTPUT/CodexUsageWidgetExtension" "$EXTENSION_CONTENTS/MacOS/CodexUsageWidgetExtension"
cp "$SCRIPT_DIR/WidgetExtension/Info.plist" "$EXTENSION_CONTENTS/Info.plist"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/Scripts/claude_bridge.py" "$APP_BUNDLE/Contents/Resources/claude_bridge.py"
cp "$SCRIPT_DIR/Scripts/claude_desktop.py" "$APP_BUNDLE/Contents/Resources/claude_desktop.py"

# File-provider metadata on generated bundles is not accepted by codesign.
xattr -dr com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_BUNDLE" 2>/dev/null || true
codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$EXTENSION_BUNDLE"
codesign --force --sign - --entitlements "$HOST_ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep "$APP_BUNDLE"

print "Built: $APP_BUNDLE"
print "Widget extension: $EXTENSION_BUNDLE"
