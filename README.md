# Codex Usage Widget MVP

## Codex + Claude (0.4.1)

하나의 앱이 메뉴바에 `CX 72% · CL 48%`처럼 두 서비스의 **남은 비율**을 표시합니다.
클릭한 뒤 모두/Codex/Claude를 선택하면 메뉴바 표시를 전환할 수 있습니다.
5시간·주간 중 남은 비율이 더 적은 한도를 대표로 표시하며, 같으면 5시간을 선택합니다.
단독 모드는 기존 작은 직사각형 디자인입니다. `W`는 주간 한도, `*`는 10분 이상
지난 관측값입니다. 초기화 시각이 지나면 새 관측까지 미확인으로 표시합니다.
위젯 갤러리에는 Codex·Claude 작은 위젯과 두 서비스를 나란히 표시하는 중간 위젯이 있습니다.

### Claude 데스크톱 Code 탭 직접 조회 (선택·권장)

사용자가 인증 접근을 승인한 경우, 현재 계정·조직과 일치하는 데스크톱 OAuth 인증을
메모리에서만 읽고 `https://api.anthropic.com/api/oauth/usage`에만 전송합니다.
다른 주소로 리다이렉트하지 않으며 토큰·키체인 비밀은 로그나 캐시에 저장하지 않습니다.
Claude 앱의 인증을 갱신하거나 변경하지 않습니다. 토큰이 만료되면 Code 탭에서 로그인 상태를
갱신해야 합니다. 비공식 내부 인터페이스이므로 Claude 업데이트에 따라 변경될 수 있습니다.

2분 간격으로 서버 수치와 초기화 시각을 조회합니다. 429가 이어지면 재시도 간격을
5분·10분·20분으로 늘리며, 20분을 상한으로 유지합니다. 성공하거나 다른 실패를 받으면
2분 간격으로 돌아갑니다. 실패 시 같은 계정·조직의 마지막 성공 값을 최대 60분 유지하고,
초기화 시각이 지난 창은 제외합니다. 원래 관측 시각을 유지하며 팝오버에는 마지막 조회
시각·결과와 이전 값 표시 여부를 안내합니다. 계정 변경 중 응답과 다른 계정의 값은 폐기합니다.
유효한 직접 조회 값이 없으면 같은 계정의 앱 기록을 대신 표시합니다.
위젯 갱신에는 macOS의 추가 지연이 있을 수 있습니다.

팝오버의 **Claude 직접 조회** 토글로 켜고 끌 수 있습니다. 터미널에서도 설정할 수 있습니다.

```sh
/usr/bin/python3 "$HOME/Applications/Codex Usage.app/Contents/Resources/claude_bridge.py" enable-desktop-direct
```

키체인 접근 허용이 필요할 수 있습니다. 접근이 거부되거나 시간 초과로 확인할 수 없으면
직접 조회와 이전 직접 조회 값 표시를 중단하고 앱 기록을 확인합니다. 토글을 껐다 켜거나
`enable-desktop-direct`를 다시 실행하면 차단과 재시도 상태를 초기화합니다.
해제하면 직접 조회 상태와 유지 값을 모두 지웁니다. 터미널에서는 마지막 인수를
`disable-desktop-direct`로 바꾸세요. 승인 설정은 이 Mac에만 저장됩니다.

### Claude 데스크톱 이력 읽기 (직접 조회를 끄거나 조회 값이 없을 때)

데스크톱 앱의 `plan-usage-history.json`을 읽습니다. 터미널 CLI 설치나 상태 표시줄 설정이
필요하지 않습니다. 첫 연결에서는 로그인·조직 갱신 시각 이후의 기록만 허용합니다.
계정·조직 변경 후에는 **Claude 앱에서 사용량을 열고** 새 기록이 저장될 때까지 기다리세요.
Claude 앱은 기록을 최소 약 4.5분 간격으로 저장하며 백그라운드에서는 더 오래 걸릴 수 있어
화면의 실시간 수치와 잠시 차이가 날 수 있습니다. 위젯은 이 기록을 30초마다 확인합니다.
초기화 시각은 기록에 없어 `미제공`으로 표시하며 추정하지 않습니다.
메뉴바와 위젯은 마지막 앱 기록을 최대 30분 표시합니다. 10분 경과 시 메뉴바에 `*`를 붙이고,
30분이 지나면 메뉴바는 `—`로 표시하고 상세 화면과 위젯도 수치를 숨깁니다.
이 수집 경로만으로 Claude 화면의 실시간 수치와 일치하는 표시는 보장할 수 없습니다.

이 파일은 공식 외부 API가 아닌 현재 설치본의 로컬 기록 형식(version 2)입니다.
형식이 바뀌면 수치를 숨깁니다. 계정 UUID와 암호화된 조직 식별자의 해시로 전환을 감지하며,
로그인 쿠키는 존재·만료 여부와 갱신 시각만 확인합니다. 로그인 토큰을 읽거나 복호화하지 않습니다.
앱이 종료된 동안 또는 계정 상태를 확인할 수 없을 때 새 수치 조회는 보장하지 않습니다.

### Claude 터미널 연결 (선택)

Claude Code CLI와 Python 3가 필요합니다. 아래 연결 명령을 실행하면
사용자 설정의 기존 상태 표시줄을 보존하는 래퍼와 SessionStart 훅을 추가합니다.
기존 설정은 `~/.claude/settings.json.usage-backup-시각`에 백업됩니다.
연결 후 **새 터미널 Claude 세션을 시작**하고 정상 응답을 한 번 받으세요.
기존에 열려 있던 세션과 계정 변경 전 세션은 재시작해야 합니다.
프로젝트 설정이 사용자 statusLine을 덮어쓰는 경우 해당 프로젝트에서는 수집되지 않습니다.
사용자 지정 CLAUDE_CONFIG_DIR은 아래 명령의 --config-dir 옵션으로 지정하세요.

```sh
/usr/bin/python3 "$HOME/Applications/Codex Usage.app/Contents/Resources/claude_bridge.py" connect
```

연결 해제는 추가한 훅과 상태 표시줄 연결만 복원하고 다른 설정 변경은 보존합니다.

```sh
/usr/bin/python3 "$HOME/Applications/Codex Usage.app/Contents/Resources/claude_bridge.py" disconnect
```

공식 [statusLine 데이터](https://code.claude.com/docs/en/statusline)의
`rate_limits.five_hour`와 `seven_day`만 사용합니다. 소수 사용률은 올림해 잔여량을
과대 표시하지 않습니다. 컨텍스트 점유율이나 로컬 토큰 비용을 구독 한도로 환산하지 않습니다.
Pro/Max 구독에서 첫 응답 이후 한도가 제공되며 API 인증·누락 필드는 미확인으로 처리합니다.
Claude를 종료하면 마지막 관측값만 남습니다. 다른 기기의 사용량을 독립적으로 조회하지 않습니다.
계정은 `claude auth status`로 확인하고 해시만 저장하며 이메일·토큰·대화는 저장하지 않습니다.
계정 확인은 수집 시 및 앱의 30초 폴링에서 수행하며, 계정 식별이 불가능하면 수치를 숨깁니다.
여러 계정을 다른 설정 디렉터리로 동시에 쓰는 기능은 지원하지 않습니다.

검증:

```sh
python3 -m unittest discover -s Tests -v
swift run CodexUsageCoreSmoke
zsh ./build-widget-app.sh
```

맥북용 Codex 사용량 위젯의 안전한 MVP입니다.

## 현재 구현된 범위

- Swift 6 / macOS 14 이상을 대상으로 하는 `CodexUsageCore` 데이터 모델
- 5시간·주간 사용량, 남은 비율, 초기화 시각, 초기화 크레딧 표현
- 자격 증명이나 네트워크를 사용하지 않는 오프라인 fixture 공급자
- 로컬 `codex app-server`를 통한 활성 ChatGPT 계정·rate limit 읽기
- 메뉴 막대 팝오버 앱 소스
- 녹색 강조색의 `systemSmall` WidgetKit 바탕화면 위젯
- 위젯 슬롯이 위치와 정사각형 크기를 관리하므로 화면 밖으로 사라지지 않는 앱 번들
- WidgetKit 확장 소스와 수동 번들 생성 스크립트
- ISO-8601 JSON 캐시 공급자와 오프라인 smoke 검증
- `Examples/usage-snapshot.json`으로 로컬 캐시 입력 형식 제공

## 데이터 경계

`LocalJSONUsageProvider`는 앱 지원 디렉터리의 `usage-snapshot.json`만 읽습니다.
`AppServerUsageProvider`는 공식 Codex App Server의 `account/read`와
`account/rateLimits/read`를 사용합니다. `~/.codex/auth.json`이 있는 디렉터리를 감시하고
계정 fingerprint가 바뀌면 기존 사용량을 즉시 숨긴 뒤 새 계정의 한도를 다시 읽습니다.
5분 폴링은 파일 변경 이벤트를 놓쳤을 때의 안전망으로 유지합니다. 이메일과 토큰은
저장하거나 화면에 표시하지 않고, 계정 변경 감지용 단방향 해시만 캐시에 기록합니다.
조회 도중 계정이 다시 바뀌면 이전 응답은 폐기합니다.

메뉴 막대 앱이 최신 스냅샷을
`~/Library/Application Support/com.jino.codex-usage/usage-snapshot.json`에 기록하고,
WidgetKit 확장이 먼저 자신의 샌드박스 컨테이너 안 캐시를 읽습니다. 로컬 adhoc 서명에서는
App Group(`group.com.jino.codex-usage`)이 Team ID·프로비저닝 없이 보호될 수 있으므로, 로컬
실행 경로에서는 App Group 조회를 건너뛰고 메뉴 막대 앱이 같은 JSON을 위젯 확장의
컨테이너에도 미러링합니다. 정식 서명·프로비저닝 환경에서는 App Group 공유 캐시를 사용할
수 있도록 entitlement와 보조 API를 남겨두었습니다. 새 값을 저장하면 해당 위젯의 타임라인도
갱신합니다. 팝오버 안내용 `detail`만 바뀌면 위젯 캐시와 타임라인은 갱신하지 않습니다.
계정별 캐시를 별도로 저장하고, fallback 시에도 현재 계정 fingerprint와
일치하는 캐시만 허용합니다.

App Server에 연결할 수 없으면 같은 계정의 마지막 성공 값을 최대 60분 표시하며
초기화 시각이 지난 창은 제외합니다. 60분이 지나면 수치를 숨기고 재조회 안내를 표시합니다.
10초 간격으로 재시도하며, 조회 응답은 최대 10초 기다립니다. 최신 ChatGPT 앱의
`codex-cli/CodexCLI.app/Contents/MacOS/codex` 실행 경로도 지원합니다.
샘플 데이터는 위젯 미리보기 전용이며 실제 계정
사용량으로 해석하면 안 됩니다.

## 빌드

```sh
cd "/path/to/codex-usage-check"
swift run CodexUsageCoreSmoke
swift build
zsh ./build-widget-app.sh
```

활성 Codex 계정에 대한 읽기 전용 연결을 확인하려면 다음을 실행합니다.

```sh
CODEX_USAGE_LIVE_PROBE=1 swift run CodexUsageCoreSmoke
```

메뉴 막대·WidgetKit 앱은 `/private/tmp/codex-usage-widget-build/Codex Usage.app`으로 묶이며, 현재는 로컬 개발용
adhoc 서명 번들입니다. `build-widget-app.sh`가 `Contents/PlugIns` 아래에
샌드박스 및 App Group 권한이 포함된 `CodexUsageWidgetExtension.appex`를 넣습니다.
빌드만 하면 이 경로에 사본이 남습니다. `install.sh`는 설치를 마친 뒤 이 빌드 사본을
등록 해제하고 삭제하며, 같은 폴더의 Swift 빌드 캐시는 유지합니다.

앱을 한 번 실행한 뒤 macOS 위젯 갤러리에서 `Codex 사용량`을 추가하고 바탕화면의
달력 위젯과 같은 작은 정사각형 슬롯에 배치합니다. 위치와 크기는 macOS가 관리하므로
일반 창처럼 화면 밖으로 드래그할 수 없습니다. 위젯 갤러리에 보이지 않으면 앱을 한 번
종료했다가 다시 실행한 뒤 위젯 갤러리를 열어 등록합니다.

메뉴 막대 앱과 위젯 번들을 빌드해 직접 시작하려면 다음을 실행합니다.

```sh
cd "/path/to/codex-usage-check"
zsh ./run-desktop-widget.sh
```

설치와 버전 올리기는 저장소 루트에서 같은 명령으로 실행합니다. 최신 소스를 받은 뒤
아래 스크립트를 실행하면 `~/Applications/Codex Usage.app`에 설치합니다.

```sh
cd "/path/to/codex-usage-check"
zsh ./install.sh
```

설치 도우미는 빌드 사본의 번들 ID·실행 파일·서명을 확인하고 설치 폴더 옆에 새 사본을
완전히 복사한 뒤 다시 검증합니다. 그 뒤 로그인 자동 실행을 내리고, 설치·삭제 대상
경로에서 실행 중인 앱과 위젯만 종료합니다. 설치 폴더 전체를 교체하므로 이전 버전에만
있던 파일이 남지 않습니다. 개발용 `run-desktop-widget.sh`의 직접 실행 동작은 그대로입니다.

새 사본이 설치된 뒤 `~/Applications`와 `/Applications`에서 `Codex Usage.app` 또는
`Codex Usage.app.bak-`로 시작하는 사본을 찾아 위젯·앱 등록을 해제하고 삭제합니다.
번들 ID가 `com.jino.codex-usage`이고 실행 파일 이름이 `CodexUsageMenuBar`인 실제 폴더만
삭제하며, 이름이 같아도 다른 제품이거나 심볼릭 링크이면 경로를 안내하고 보존합니다.
설치 경로에 다른 항목이 있으면 교체하지 않고 중단합니다.

복사·서명 검증·프로세스 종료에 실패하면 기존 설치본과 이전 사본을 유지합니다.
교체 실패 시 기존 설치본을 되돌리고, 복구에도 실패하면 이전 사본이 남은 경로를 안내합니다.
자동 실행을 이미 내린 뒤 실패했으며 설치본이 남아 있으면 기존 LaunchAgent를 다시 올립니다.
이전 사본의 등록 해제는 미등록 상태 등으로 실패해도 삭제를 계속합니다.
설치 후 이전 사본의 삭제만 실패하면 다른 사본의 정리를 계속하고 실패 경로와 이유를
표시합니다. 새 앱 등록과 로그인 자동 실행까지 마친 뒤 정리가 끝나지 않았다는 안내와
오류 코드로 종료합니다. 새 설치본은 유지되며, 권한 문제를 해결한 뒤 설치 명령을
다시 실행할 수 있습니다.

사용량 캐시·직접 조회 승인 등 `~/Library/Application Support/com.jino.codex-usage`의 데이터,
위젯 컨테이너와 `~/.claude` 설정은 삭제하거나 수정하지 않습니다.

## 로그인 자동 실행

현재 설치본은 사용자 계정 전용 LaunchAgent로 등록되어 있습니다.

- 앱 경로: `~/Applications/Codex Usage.app`
- 설정 경로: `~/Library/LaunchAgents/com.jino.codex-usage.desktop.plist`
- 로그인 시 자동 시작: `RunAtLoad=true`
- 예기치 않은 종료 시 재실행: `KeepAlive=true`

자동 실행을 중지하려면 다음을 실행합니다.

```sh
launchctl bootout gui/$(id -u)/com.jino.codex-usage.desktop
```

다시 등록하려면 다음을 실행합니다.

```sh
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.jino.codex-usage.desktop.plist"
launchctl kickstart -k gui/$(id -u)/com.jino.codex-usage.desktop
```

현재 Command Line Tools 환경에는 XCTest 모듈이 제공되지 않아, 기본 검증은 동일한
불변식을 확인하는 smoke 실행 파일로 제공합니다.

예제 JSON을 앱 캐시로 사용하려면 파일을 다음 경로에 복사합니다.

`~/Library/Application Support/com.jino.codex-usage/usage-snapshot.json`

실제 앱에서 캐시가 없으면 갱신 대기를 표시합니다. 샘플은 미리보기와 테스트 전용입니다.
