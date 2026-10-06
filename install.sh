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
install_result=0
if /usr/bin/python3 "$SCRIPT_DIR/Scripts/install_app.py" --source "$APP_SOURCE" --destination "$APP_DESTINATION"; then
    :
else
    install_result=$?
    # Code 4 leaves a valid new app in place; finish registration before reporting it.
    if (( install_result != 4 )); then
        # Code 3 means the helper unloaded the agent before the installation failed.
        if (( install_result == 3 )) && [[ -f "$AGENT_DESTINATION" && -x "$APP_DESTINATION/Contents/MacOS/CodexUsageMenuBar" ]]; then
            print -u2 "설치 실패 전의 로그인 자동 실행을 복원합니다."
            launchctl bootstrap "$DOMAIN" "$AGENT_DESTINATION" || true
            launchctl kickstart -k "$DOMAIN/$LABEL" || true
        fi
        exit "$install_result"
    fi
fi
mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/ditto "$AGENT_SOURCE" "$AGENT_DESTINATION"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DESTINATION"
/usr/bin/pluginkit -a "$APP_DESTINATION/Contents/PlugIns/CodexUsageWidgetExtension.appex"
launchctl bootstrap "$DOMAIN" "$AGENT_DESTINATION"
launchctl kickstart -k "$DOMAIN/$LABEL"

if (( install_result == 4 )); then
    print -u2 "새 앱 등록과 자동 실행은 마쳤지만 이전 사본 정리가 끝나지 않았습니다. 삭제 실패 경로와 권한을 확인하세요."
    exit "$install_result"
fi
print "설치 및 자동 실행 등록 완료: $APP_DESTINATION"
print "로그인 자동 실행: $AGENT_DESTINATION"
