# Interface Contract

## Inputs

| 진입점 | 입력 | 소유자 |
| --- | --- | --- |
| `ProviderRuntime.init` | `ProviderCredentialVault`, 선택적 `ProviderClock` | 호출자 |
| `register` | `ProviderAccountRegistrationRequest` | 호출자 |
| `registerOpenRouterOAuth` | OAuth registration request와 `ProviderAuthorizationSession` | 호출자 + Apple adapter |
| `inspect`, `models`, `revoke` | `ProviderAccountID` | 호출자 |
| `execute` | 검증된 `ProviderTurnRequest` | 호출자 |
| `cancel` | `ProviderRequestID` | 호출자 |

`ProviderTurnRequest`는 immutable selection, messages, tool definition/choice, output,
reasoning, continuation과 timeout·byte·retry·privacy constraint를 담는다. 생성자가
형식과 상한을 검증하며 Runtime은 Provider/account/model route를 임의로 바꾸지 않는다.
`Codable` 왕복은 이 필드를 모두 보존한다. 정책이 직렬화에서 사라지면 `.required` tool
choice가 `.automatic`으로 조용히 낮아지므로, 왕복 보존은 회귀 테스트로 고정한다.

Credential은 Runtime 생성 시 주입한 `ProviderCredentialVault`를 통해서만 읽는다.
API key와 OAuth-derived key의 실제 secret 저장은 호출자 책임이다. Soa
`auth.json`은 다른 시스템이 관리하는 외부 입력이며 ProviderKit은 secret을 복사하지
않고 vault가 보존한 검증된 파일 참조를 읽는다.

## Outputs

| 작업 | 출력 | 종료 규칙 |
| --- | --- | --- |
| account 등록 | `ProviderAccountEventStream` | `ready`, `failed`, `recoveryRequired` 중 하나 |
| turn 실행 | `ProviderEventStream` | `.terminal(.completed/.cancelled/.failed)` 정확히 한 번 |
| inspect | `ProviderAccountInspection` | 성공값 또는 typed `ProviderFailure` |
| models | `ProviderModelCatalogResult` | 성공값 또는 typed `ProviderFailure` |
| reconciliation | `ProviderCredentialReconciliationReport` | 모든 정리 실패를 누락 없이 포함 |

두 event stream은 single-consumer다. 두 번째 iterator 또는 동시 `next()`는 명시적
실패다. partial tool argument는 출력하지 않으며 완성·검증된 tool call만 공개한다.
오류 메시지는 credential/token 패턴을 redaction하고 1,024자로 제한한다.

## Artifacts and persistence

ProviderKit은 실행 중 파일, 대화 기록, UI state, tool receipt, 문서 artifact를
생성하거나 저장하지 않는다. stream 출력은 메모리 내 event이며 보존이 필요하면
호출자가 durable store로 투영한다.

| 항목 | 분류 | 관리 규칙 |
| --- | --- | --- |
| `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `Docs/` | canonical source input | 저장소에서 관리 |
| Git commit | canonical source identity | clean working tree를 commit으로 고정 |
| semantic version tag | release identity | 검증된 release commit에만 부여 |
| release archive와 checksum | 배포 artifact | tagged commit에서 생성하고 checksum은 archive 밖에 게시 |
| `Package.resolved` | 선택적 dependency resolution 기록 | 생성되면 검토·추적; build cache로 취급하지 않음 |
| `.build/`, `.swiftpm/`, DerivedData | 재생성 가능한 build output | 저장소에 보존하지 않음 |
| credential secret | 외부 runtime input | 호출자 vault가 보관; 문서·로그·artifact에 기록 금지 |
| Soa `auth.json` | caller-managed external input | 경로만 참조; 복사·수정하지 않음 |
| model event stream | ephemeral output | 호출자가 소비·저장·UI 투영 |
| `Docs/COMPLETION_REPORT.md` | 검증 기록 | 실제 명령 결과만 기록 |

Git tree가 파일 집합과 내용을 함께 식별한다. release archive는 commit 전 파일 복사본이
아니라 tagged commit에서 생성한다. archive checksum이나 서명은 archive 내부가 아닌
release metadata로 게시해 artifact와 독립된 검증 근거를 제공한다.

## Credential vault contract

호출자 vault는 다음을 보장해야 한다.

- `stage`는 새 immutable record identity를 만들고 아직 active lease로 노출하지 않는다.
- `activate` 뒤 `record(accountID:)`가 같은 reference, account, provider, source를 반환한다.
- `lease`는 active record와 그 record에 대응하는 material만 반환한다.
- `remove`는 정확한 record를 삭제하고 다른 계정의 credential을 건드리지 않는다.
- `records`는 reconciliation 가능한 staged/active record 전체를 반환한다.

ProviderKit은 concrete Keychain adapter, 평문 파일 vault, `UserDefaults` vault,
저장소 migration이나 legacy raw-value decoder를 제공하지 않는다.

## Lifecycle

호출자는 앱/서비스 종료 전에 `await runtime.shutdown()`을 호출한다. shutdown 시작 뒤
신규 register/execute/control operation은 fail-closed하며, 기존 child task와 transport는
cancel/join된다. 개별 turn 취소는 `cancel(requestID)`, 계정 제거는 `revoke(accountID:)`
를 사용한다.
