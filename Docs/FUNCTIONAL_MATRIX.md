# Functional Matrix

판정 기준은 실제 코드와 테스트다. `PASS`는 현재 package가 소유하는 기능이 실행 검증된 상태, `OUTSIDE`는 호출자 제품이 소유하는 기능, `LIVE_REQUIRED`는 구현과 fixture 검증은 완료됐지만 외부 계정 검증이 필요한 상태다.

| ID | 기능 | 소유권 | 구현 근거 | 검증 근거 | 상태 |
| --- | --- | --- | --- | --- | --- |
| F-01 | Agent orchestration | 호출자 제품 | ProviderKit은 Agent gateway를 import하지 않음 | boundary verifier | OUTSIDE |
| F-02 | 대화 1회 직접 응답 | ProviderKit | `ProviderRuntime.execute`, `ProviderExecutionSupervisor` | direct streaming test | PASS |
| F-03 | plan/work/review orchestration | 호출자 제품 | ProviderKit은 1-turn만 제공 | target/import graph | OUTSIDE |
| F-04 | 실제 text·displayable reasoning streaming | ProviderKit | HTTP/SSE decoder → `.textDelta`·`.reasoningDelta` | fragmentation·normalization·reasoning separation runtime tests | PASS |
| F-05 | cancel·terminal exactly-once | ProviderKit | admission-ordered session start, execution reducer/session, single session registry with early ID release | immediate cancel, deadline, cleanup, reuse, shutdown, execute/shutdown interleaving tests | PASS |
| F-06 | bounded backpressure | ProviderKit | bounded mailbox, terminal reserved slot, text batch, bounded transport body buffer | core/runtime mailbox overflow, transport backpressure tests | PASS |
| F-07 | account readiness inspect | ProviderKit | `verificationRequired → inspect → ready`, credential contract | restart/readiness, invalid/no-op/source mismatch tests | PASS |
| F-08 | Codex external auth file | ProviderKit | `SecureRegularFileReader`, declared Codex wire version, Codex adapter | symlink·size·header injection·declared-version tests, account/catalog/turn live flow | PASS |
| F-09 | OpenRouter direct 호출 | ProviderKit | direct HTTP/SSE adapter | request/privacy/OAuth fixtures | LIVE_REQUIRED |
| F-10 | API key 계정 | ProviderKit + 선택적 호출자 저장 adapter | `InMemoryProviderCredentialStore` 또는 `ProviderCredentialStore` 주입 | public in-memory lifecycle + registration transaction tests | LIVE_REQUIRED |
| F-11 | OAuth 계정 | ProviderKit + Apple | documented OpenRouter PKCE URL, loopback callback state·origin·query validation | PKCE URL shape, callback/replay tests | LIVE_REQUIRED |
| F-12 | 복수 계정 격리 | ProviderKit | account ID keyed supervisor/store/continuation | registration/revoke/continuation isolation tests | PASS |
| F-13 | model catalog·exact ID | ProviderKit | strict catalog parser, `ProviderModelID`, optional output-token limit | malformed/duplicate/limit catalog tests | LIVE_REQUIRED |
| F-14 | stage별 route | 호출자 제품 | `ProviderSelection` 값만 제공 | boundary verifier | OUTSIDE |
| F-15 | capability qualification | ProviderKit + 호출자 | descriptor/catalog capability 상태 | strict decode tests | LIVE_REQUIRED |
| F-16 | structured output·reasoning 정책 | ProviderKit + caller | Provider별 output constraint, dialect별 reasoning 인코딩 또는 명시적 거부 | native/application-validated, reasoning policy tests | PASS |
| F-17 | tool call 정규화·선택 | ProviderKit | bounded accumulator, completed call only, caller-owned call/result history (실패 결과 `isError` 포함), declared-tool allowlist | history/error-result wire round-trip, malformed/oversize/identity/tool-choice, Gemini stateless history fail-closed tests | PASS |
| F-18 | tool 실행 권위 | 호출자 제품 | 실행 API 없음 | public API/boundary inspection | OUTSIDE |
| F-19 | usage 계측 | ProviderKit | normalized `ProviderUsage`, usage-only compatible chunk | malformed/overflow/usage-only tests | PASS |
| F-20 | privacy/data routing | ProviderKit + 호출자 | request constraints → Provider wire | OpenRouter privacy fixture | PASS |
| F-21 | retry | ProviderKit | reducer의 same-route bounded pre-output retry 전이 | 401/429/opened-transport failure/visible-output tests | PASS |
| F-22 | cross-provider fallback | 호출자 제품 정책 | ProviderKit에서 금지 | request fixture·constraint validation | PASS |
| F-23 | 오류 정규화·redaction | ProviderKit | `ProviderFailure`, whitelisted URL/core/transport error mapping | secret/status/malformed JSON/unclassified error tests | PASS |
| F-24 | revoke·credential recovery | ProviderKit + 호출자 저장 adapter | staged transaction, compensation, reconciliation | crash-state/revoke/cancel race tests | LIVE_REQUIRED |
| F-25 | Provider/account/model 선택 값 | ProviderKit | open identifiers, immutable selection | round-trip/request tests | PASS |
| F-26 | 사용자 승인 | 호출자 제품 | readiness만 제공 | boundary verifier | OUTSIDE |
| F-27 | settings import fence | 호출자 제품 | shutdown/drain만 제공 | runtime shutdown tests | OUTSIDE |
| F-28 | 외부 local Agent process | 호출자 제품 | 구현 없음 | package graph | OUTSIDE |
| F-29 | MCP/CLI tool | 호출자 제품 | 구현 없음 | package graph | OUTSIDE |
| F-30 | 문서 artifact 저장 | 호출자 제품 | 구현 없음 | package graph | OUTSIDE |
| F-31 | 가짜 rechunk 제거 기반 | ProviderKit | native stream만 공개 | direct delta tests | PASS |
| F-32 | 외부 subprocess 없는 direct provider 호출 | ProviderKit | OpenRouter direct adapter | fixture PASS, live qualification 필요 | LIVE_REQUIRED |
| F-33 | JSON 변환 축소 | ProviderKit | bounded `ProviderJSONValue` | deterministic round-trip tests | PASS |
| F-34 | 요청별 immutable selection·continuation policy | ProviderKit | `ProviderTurnRequest.selection`, explicit server-side retention opt-in | active request/retry/continuation wire tests | PASS |
| F-35 | runtime shutdown/drain | ProviderKit; 제품 lifecycle은 호출자 제품 | lifecycle admission fence, child join | concurrent shutdown tests | PASS |
| F-36 | caller-owned 반복 대화 | ProviderKit + 호출자 | immutable history를 포함한 연속 `execute`; durable state 없음 | Codex history wire regression, Luna 3-turn live flow | PASS |

## 구조적 불변식

| 불변식 | 코드 경계 | 회귀 |
| --- | --- | --- |
| reducer는 부수 효과를 호출하지 않음 | Core account/execution reducer | reducer tests |
| 공유 가변 상태만 actor 격리 | runtime/account/execution/replay/store; 실행별 decoder는 local | Thread Sanitizer |
| 동기 URLSession callback은 lock, `yield`는 lock 밖 | `HTTPTransport` | cancel/failure/sanitizer tests |
| terminal 이전 cleanup 및 종료 join | execution/account session은 `run` 종료까지 등록 유지, ID만 조기 해제 | cleanup ordering, immediate cancel, shutdown, interleaving tests |
| credential commit 이전 read-back | account session/credential contract | no-op activation/source mismatch tests |
| 취소가 commit보다 먼저 이기면 보상 삭제 | account session | non-cooperative stage/activation tests |
| unbounded input 없음 | Core values, HTTP/SSE/JSON/tool/mailbox/loopback listener | bound/overflow/listener tests |
| 공개 정책은 wire 반영 또는 명시적 거부 | output requirement·reasoning policy | native schema·reasoning policy tests |
| tool choice는 wire 반영 또는 명시적 거부 | `ProviderToolChoice`와 adapter | named/required encoding, Gemini fail-closed test |
| transport 종료 신호는 모든 경로에서 발화 | `HTTPTransport` 완료·무효화 delegate | cancel/invalidation/termination-order tests |
| 성장 입력에 대한 O(n²) scan 없음 | SSE/header cursor, account→execution 역색인, bounded amortized mailbox compaction | fragmented scan·revoke isolation tests |
