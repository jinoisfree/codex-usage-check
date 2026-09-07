# Codex Usage Widget MVP

맥북용 Codex 사용량 위젯의 안전한 MVP입니다.

## 현재 구현된 범위

- Swift 6 / macOS 14 이상을 대상으로 하는 `CodexUsageCore` 데이터 모델
- 5시간·주간 사용량, 남은 비율, 초기화 시각, 초기화 크레딧 표현
- 자격 증명이나 네트워크를 사용하지 않는 오프라인 fixture 공급자
- 로컬 `codex app-server`를 통한 활성 ChatGPT 계정·rate limit 읽기
- 메뉴 막대 팝오버 앱 소스
- 녹색 강조색의 초소형(`300×210`) 아이콘 뒤 바탕화면 desktop-level 오버레이 창
- WidgetKit 확장 소스(`WidgetExtension/CodexUsageWidget.swift`)
- ISO-8601 JSON 캐시 공급자와 오프라인 smoke 검증
- `Examples/usage-snapshot.json`으로 로컬 캐시 입력 형식 제공

## 데이터 경계

`LocalJSONUsageProvider`는 앱 지원 디렉터리의 `usage-snapshot.json`만 읽습니다.
`AppServerUsageProvider`는 공식 Codex App Server의 `account/read`와
`account/rateLimits/read`를 사용합니다. `account/updated` 이벤트를 직접 구독하는 대신
5분마다 활성 계정을 다시 읽으므로, Codex에서 계정을 바꾸면 다음 갱신부터 새 계정의
한도로 따라갑니다. 이메일과 토큰은 저장하거나 화면에 표시하지 않고, 계정 변경 감지용
단방향 해시만 메모리에 유지합니다.

App Server에 연결할 수 없으면 승인된 로컬 JSON 캐시, 그 다음 샘플 데이터 순으로
fallback합니다. 샘플 데이터는 실제 계정 사용량으로 해석하면 안 됩니다.

## 빌드

```sh
cd "/Users/jinoisfree/.codex/visualizations/2026/09/07/01a07ba6-7a03-71f1-a43b-5ab957ad7459/CodexUsageWidgetMVP"
swift run CodexUsageCoreSmoke
swift build
```

활성 Codex 계정에 대한 읽기 전용 연결을 확인하려면 다음을 실행합니다.

```sh
CODEX_USAGE_LIVE_PROBE=1 swift run CodexUsageCoreSmoke
```

메뉴 막대·바탕화면 MVP 앱은 `AppBundle/Codex Usage.app`으로 묶이며, 현재는 로컬 개발용
adhoc 서명 번들입니다. WidgetKit 확장은 별도 Xcode Widget Extension target과 App Group
설정이 필요합니다.

바탕화면 오버레이를 직접 시작하려면 다음을 실행합니다.

```sh
cd "/Users/jinoisfree/.codex/visualizations/2026/09/07/01a07ba6-7a03-71f1-a43b-5ab957ad7459/CodexUsageWidgetMVP"
zsh ./run-desktop-widget.sh
```

## 로그인 자동 실행

현재 설치본은 사용자 계정 전용 LaunchAgent로 등록되어 있습니다.

- 앱 경로: `/Users/jinoisfree/Applications/Codex Usage.app`
- 설정 경로: `/Users/jinoisfree/Library/LaunchAgents/com.jino.codex-usage.desktop.plist`
- 로그인 시 자동 시작: `RunAtLoad=true`
- 예기치 않은 종료 시 재실행: `KeepAlive=true`

자동 실행을 중지하려면 다음을 실행합니다.

```sh
launchctl bootout gui/$(id -u) "/Users/jinoisfree/Library/LaunchAgents/com.jino.codex-usage.desktop.plist"
```

다시 등록하려면 다음을 실행합니다.

```sh
launchctl bootstrap gui/$(id -u) "/Users/jinoisfree/Library/LaunchAgents/com.jino.codex-usage.desktop.plist"
launchctl kickstart -k gui/$(id -u)/com.jino.codex-usage.desktop
```

현재 Command Line Tools 환경에는 XCTest 모듈이 제공되지 않아, 기본 검증은 동일한
불변식을 확인하는 smoke 실행 파일로 제공합니다.

예제 JSON을 앱 캐시로 사용하려면 파일을 다음 경로에 복사합니다.

`~/Library/Application Support/com.jino.codex-usage/usage-snapshot.json`

메뉴 막대 앱은 해당 파일을 읽지 못하면 샘플 데이터를 표시합니다. 샘플 데이터는
실제 계정 사용량으로 해석하면 안 됩니다.

`WidgetExtension/CodexUsageWidget.swift`는 Xcode의 Widget Extension target에 추가하고,
메뉴 막대 앱과 동일한 App Group을 연결하면 캐시를 공유하는 다음 단계로 확장할 수 있습니다.
