# Codex Usage Widget MVP

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
`account/rateLimits/read`를 사용합니다. `account/updated` 이벤트를 직접 구독하는 대신
5분마다 활성 계정을 다시 읽으므로, Codex에서 계정을 바꾸면 다음 갱신부터 새 계정의
한도로 따라갑니다. 이메일과 토큰은 저장하거나 화면에 표시하지 않고, 계정 변경 감지용
단방향 해시만 메모리에 유지합니다.

메뉴 막대 앱이 최신 스냅샷을
`~/Library/Application Support/com.jino.codex-usage/usage-snapshot.json`에 기록하고,
WidgetKit 확장이 먼저 자신의 샌드박스 컨테이너 안 캐시를 읽습니다. 로컬 adhoc 서명에서는
App Group(`group.com.jino.codex-usage`)이 Team ID·프로비저닝 없이 보호될 수 있으므로, 로컬
실행 경로에서는 App Group 조회를 건너뛰고 메뉴 막대 앱이 같은 JSON을 위젯 확장의
컨테이너에도 미러링합니다. 정식 서명·프로비저닝 환경에서는 App Group 공유 캐시를 사용할
수 있도록 entitlement와 보조 API를 남겨두었습니다. 새 값을 저장하면 해당 위젯의 타임라인도
갱신합니다.

App Server에 연결할 수 없으면 승인된 로컬 JSON 캐시, 그 다음 샘플 데이터 순으로
fallback합니다. 샘플 데이터는 실제 계정 사용량으로 해석하면 안 됩니다.

## 빌드

```sh
cd "/Users/jinoisfree/.codex/visualizations/2026/09/07/01a07ba6-7a03-71f1-a43b-5ab957ad7459/CodexUsageWidgetMVP"
swift run CodexUsageCoreSmoke
swift build
zsh ./build-widget-app.sh
```

활성 Codex 계정에 대한 읽기 전용 연결을 확인하려면 다음을 실행합니다.

```sh
CODEX_USAGE_LIVE_PROBE=1 swift run CodexUsageCoreSmoke
```

메뉴 막대·WidgetKit 앱은 `AppBundle/Codex Usage.app`으로 묶이며, 현재는 로컬 개발용
adhoc 서명 번들입니다. `build-widget-app.sh`가 `Contents/PlugIns` 아래에
샌드박스 및 App Group 권한이 포함된 `CodexUsageWidgetExtension.appex`를 넣습니다.

앱을 한 번 실행한 뒤 macOS 위젯 갤러리에서 `Codex 사용량`을 추가하고 바탕화면의
달력 위젯과 같은 작은 정사각형 슬롯에 배치합니다. 위치와 크기는 macOS가 관리하므로
일반 창처럼 화면 밖으로 드래그할 수 없습니다. 위젯 갤러리에 보이지 않으면 앱을 한 번
종료했다가 다시 실행한 뒤 위젯 갤러리를 열어 등록합니다.

메뉴 막대 앱과 위젯 번들을 빌드해 직접 시작하려면 다음을 실행합니다.

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
