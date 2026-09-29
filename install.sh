#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_SOURCE="/private/tmp/codex-usage-widget-build/Codex Usage.app"
APP_DESTINATION="$HOME/Applications/Codex Usage.app"
AGENT_SOURCE="$SCRIPT_DIR/LaunchAgent/com.jino.codex-usage.desktop.plist"
AGENT_DESTINATION="$HOME/Library/LaunchAgents/com.jino.codex-usage.desktop.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.jino.codex-usage.desktop"

zsh "$SCRIPT_DIR/build-widget-app.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x CodexUsageMenuBar 2>/dev/null || true
# Stop the installed extension before changing its bundle/version. A suspended old
# process can otherwise archive a timeline with a mismatched bundle version.
EXTENSION_EXECUTABLE="$APP_DESTINATION/Contents/PlugIns/CodexUsageWidgetExtension.appex/Contents/MacOS/CodexUsageWidgetExtension"
for extension_pid in ${(f)$(pgrep -x CodexUsageWidgetExtension 2>/dev/null || true)}; do
    extension_command="$(ps -p "$extension_pid" -o command=)"
    if [[ "$extension_command" == "$EXTENSION_EXECUTABLE"* ]]; then
        kill -TERM "$extension_pid" 2>/dev/null || true
        for attempt in {1..30}; do
            kill -0 "$extension_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$extension_pid" 2>/dev/null; then
            print -u2 "Widget extension has not stopped; installation cancelled."
            exit 1
        fi
    fi
done
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"
/usr/bin/ditto "$AGENT_SOURCE" "$AGENT_DESTINATION"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DESTINATION"
/usr/bin/pluginkit -a "$APP_DESTINATION/Contents/PlugIns/CodexUsageWidgetExtension.appex"
launchctl bootstrap "$DOMAIN" "$AGENT_DESTINATION"
launchctl kickstart -k "$DOMAIN/$LABEL"

print "Installed: $APP_DESTINATION"
print "LaunchAgent: $AGENT_DESTINATION"
