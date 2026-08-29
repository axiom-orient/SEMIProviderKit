# Interface Contract

## Inputs

| 진입점 | 입력 | 소유자 |
| --- | --- | --- |
| `ProviderRuntime.init` | `ProviderCredentialStore`, 선택적 `ProviderClock` | package 또는 호출자 |
| `register` | `ProviderAccountRegistrationRequest` | 호출자 |
| `registerOpenRouterOAuth` | OAuth registration request와 `ProviderAuthorizationSession` | 호출자 + Apple adapter |
| `inspect`, `models`, `revoke` | `ProviderAccountID` | 호출자 |
| `execute` | 검증된 `ProviderTurnRequest` | 호출자 |
| `cancel` | `ProviderRequestID` | 호출자 |

`ProviderTurnRequest`는 immutable selection, messages, tool definition/choice, output,
reasoning, continuation과 timeout·byte·retry·privacy constraint를 담는다. 생성자가
형식과 상한을 검증하며 Runtime은 Provider/account/model route를 임의로 바꾸지 않는다.
`maximumRetryAttempts`는 최초 요청을 포함한 최대 전송 시도 수다. 따라서 기본값 `1`은
재시도를 끄고, `2`는 visible output 전 1회의 retry를 허용한다. provider endpoint fallback은
package 정책상 항상 금지되며, Codable 계약 보존을 위해 `false` 값도 직렬화한다. `Codable` 왕복은 이 필드를 모두 보존한다. 정책이 직렬화에서 사라지면 `.required` tool
choice가 `.automatic`으로 조용히 낮아지므로, 왕복 보존은 회귀 테스트로 고정한다.

## Tool round trip and trust boundary

caller-owned history에서 tool을 실행한 뒤에는 assistant의 `.toolCall(callID:name:arguments:)`와
그에 대응하는 `.toolResult`를 순서대로 보존해야 한다. `.toolResult`는 선택적
`isError` 표식(기본값 `false`)을 가지며, Codable에서는 `is_error` 키로 보존한다.
기존 저장 payload에 이 키가 없으면 `false`로 읽고, 새 payload에는 `false`도 직렬화한다.
Runtime은 이번 turn에 선언하지 않은
provider tool name과 `.named` choice 밖의 tool call을 malformed response로 거부한다. arguments는
항상 untrusted provider input이다. `inputSchema`는 provider wire 제약이며, 실제 tool 실행자는
자신의 권한·입력 검증을 별도로 적용해야 한다.

OpenAI Responses·OpenAI-compatible chat·Anthropic Messages는 이 history pair를 wire에 보존한다.
오류 표식이 `true`인 결과는 Anthropic의 qualified Messages dialect에서만 `is_error: true`로
전송된다. MiniMax-compatible Messages, Responses·Chat Completions는 기존 tool-result
payload를 유지하고 비공식 오류 필드를 추가하지 않는다. Gemini Interactions도 retention
opt-in된 qualified server-side continuation에서 `function_result` payload를 유지하지만
`is_error`를 추가하지 않는다.
Gemini stateless tool history는 provider가 반환한 모든 step(예: thought/signature)을 정확히
보존해야 하므로 이 public 모델로 재구성하지 않으며, assistant tool-call history를 fail-closed한다.

`ProviderContinuation`은 OpenAI Responses의 `previous_response_id` 또는 Gemini
Interactions의 `previous_interaction_id`처럼 provider 서버 상태를 참조한다. 이 경로는
서버 저장이 필요하므로 `dataCollection: .allow`와
`requiresZeroDataRetention: false`를 함께 명시해야 한다. 기본 no-retention 정책에서
continuation을 보내면 `capabilityMismatch`로 거부한다. 이 opt-in은 첫 요청에서도
`store: true`를 만들어 다음 응답의 continuation을 실제로 재사용할 수 있게 하며,
continuation 요청의 wire에도 `store: true`를 명시한다. continuation을 지원하지 않는
dialect는 같은 이유로 fail-closed 한다. Codex subscription endpoint는 이 저장
continuation을 qualified capability로 제공하지 않으므로 `ProviderContinuation`을
`capabilityMismatch`로 거부하고 항상 stateless request를 보낸다.

반복 대화는 caller-owned `messages`로 표현한다. 호출자는 완료된 assistant text를
`.assistant` message로 history에 넣고 새 `.user` message와 새 request ID로 다음
`execute`를 호출한다. history는 `ProviderTurnRequest`의 기존 상한 안에서만 허용되며,
package는 이를 보존하거나 provider continuation으로 바꾸지 않는다. 현재 Codex
subscription endpoint는 `maximumOutputTokens`를 qualified parameter로 제공하지 않아,
이를 설정한 request를 network 전 `capabilityMismatch`로 거부한다.

Credential은 Runtime 생성 시 주입한 `ProviderCredentialStore`를 통해서만 읽는다.
`InMemoryProviderCredentialStore`를 쓰면 API key와 OAuth-derived key는 process
lifetime에만 존재한다. durable 보존이 필요하면 실제 secret 저장은 호출자 책임이다.
Codex `auth.json`은 다른 시스템이 관리하는 외부 입력이며 ProviderKit은 secret을
복사하지 않고 store가 보존한 검증된 파일 참조를 읽는다.

`ProviderAccountOptions`는 account record와 함께 보존하는 작은 non-secret routing
metadata다. 값은 최대 16개이며 secret, token, API key를 넣을 수 없다. 현재 Antigravity
adapter는 `project-id`를 요구하고 bearer material만 허용한다. 이 adapter에는 검증된
inspect/model-catalog endpoint가 없으므로 `inspect`와 `models`는 typed
`capabilityMismatch`를 반환한다.

OpenRouter PKCE authorization URL은 provider의 documented `callback_url`,
`code_challenge`, `code_challenge_method` 형식을 그대로 사용한다. state는 loopback
callback URL에 caller-owned correlation 값으로 넣고, bound listener와 broker가 callback의
origin·path·query multiset·state를 모두 검증한다. authorization URL 최상위 query에 state가
있다는 가정은 하지 않는다.

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
`ProviderTurnEvent.reasoningDelta`는 provider가 displayable이라고 명시한 텍스트 요약만
전달한다. 일반 `.textDelta`와 순서 및 coalescing 경계가 분리되고, opaque state,
signature, redacted thought, raw private reasoning은 이 public event로 노출하지 않는다.
reasoning delta도 visible output이므로 이후 transport 실패는 retry 대상이 아니다.
오류 메시지는 credential/token 패턴을 best-effort redaction하고 1,024자로 제한한다. provider가
보낸 원격 진단 문자열일 수 있으므로 unrestricted log나 credential source로 취급하지 않는다.
`ProviderJSONValue.number`는 IEEE-754 binary64이며 2^53을 넘는 식별자 정수는 문자열로 전달해야
lossless round-trip이 가능하다.

## Artifacts and persistence

ProviderKit은 실행 중 파일, 대화 기록, UI state, tool receipt, 문서 artifact를
생성하거나 저장하지 않는다. stream 출력은 메모리 내 event이며 보존이 필요하면
호출자가 durable store로 투영한다.

| 항목 | 분류 | 관리 규칙 |
| --- | --- | --- |
| `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `Docs/` | canonical source input | 저장소에서 관리 |
| Git commit | canonical source identity | clean working tree를 commit으로 고정 |
| `Package.resolved` | 선택적 dependency resolution 기록 | 생성되면 검토·추적; build cache로 취급하지 않음 |
| `.build/`, `.swiftpm/`, DerivedData | 재생성 가능한 build output | 저장소에 보존하지 않음 |
| credential secret | 외부 runtime input | in-memory 또는 호출자 store가 보관; 문서·로그·artifact에 기록 금지 |
| Codex `auth.json` | caller-managed external input | 경로만 참조; 복사·수정하지 않음 |
| model event stream | ephemeral output | 호출자가 소비·저장·UI 투영 |

Git tree가 파일 집합과 내용을 함께 식별한다. build 산출물과 credential은 source tree에
기록하지 않으며, 호출자는 필요한 보존 정책을 자신의 제품에서 명시적으로 관리한다.

## Credential store contract

모든 store는 다음을 보장해야 한다.

- `stage`는 새 immutable record identity를 만들고 아직 active lease로 노출하지 않는다.
- `activate` 뒤 `record(accountID:)`가 같은 reference, account, provider, source를 반환한다.
- `lease`는 active record와 그 record에 대응하는 material만 반환한다.
- `remove`는 정확한 record를 삭제하고 다른 계정의 credential을 건드리지 않는다.
- `records`는 reconciliation 가능한 staged/active record 전체를 반환한다.
- `options`는 non-secret metadata만 보존하며 credential material 또는 secret storage의
  대체물이 아니다.

Package의 `InMemoryProviderCredentialStore`는 actor로 격리된 위 계약의 ephemeral
구현이다. 파일 I/O, 암호화, 권한 요청이 없고 store 또는 process 수명이 끝나면 내용이
사라진다. durable persistence가 필요하면 호출자가 같은 protocol을 구현하고 저장
기술과 보안 속성을 별도로 검증한다.

## Lifecycle

호출자는 앱/서비스 종료 전에 `await runtime.shutdown()`을 호출한다. shutdown 시작 뒤
신규 register/execute/control operation은 fail-closed하며, 기존 child task와 transport는
cancel/join된다. 개별 turn 취소는 `cancel(requestID)`, 계정 제거는 `revoke(accountID:)`
를 사용한다.
