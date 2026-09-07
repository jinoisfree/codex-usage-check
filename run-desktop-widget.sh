#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_EXECUTABLE="$SCRIPT_DIR/AppBundle/Codex Usage.app/Contents/MacOS/CodexUsageMenuBar"
LOG_PATH="/private/tmp/codex-usage-widget.log"

nohup "$APP_EXECUTABLE" >"$LOG_PATH" 2>&1 &
print "Codex Usage desktop widget started: $APP_EXECUTABLE"
print "Log: $LOG_PATH"
