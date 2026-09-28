#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_SOURCE="$SCRIPT_DIR/AppBundle/Codex Usage.app"
APP_DESTINATION="$HOME/Applications/Codex Usage.app"
AGENT_SOURCE="$SCRIPT_DIR/LaunchAgent/com.jino.codex-usage.desktop.plist"
AGENT_DESTINATION="$HOME/Library/LaunchAgents/com.jino.codex-usage.desktop.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.jino.codex-usage.desktop"

zsh "$SCRIPT_DIR/build-widget-app.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x CodexUsageMenuBar 2>/dev/null || true
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"
/usr/bin/ditto "$AGENT_SOURCE" "$AGENT_DESTINATION"
launchctl bootstrap "$DOMAIN" "$AGENT_DESTINATION"
launchctl kickstart -k "$DOMAIN/$LABEL"

print "Installed: $APP_DESTINATION"
print "LaunchAgent: $AGENT_DESTINATION"
