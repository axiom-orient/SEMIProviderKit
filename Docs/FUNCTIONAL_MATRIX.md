# Functional Matrix

판정 기준은 실제 코드와 테스트다. `PASS`는 현재 package가 소유하는 기능이 실행 검증된 상태, `OUTSIDE`는 상위 SEMI가 소유해야 하는 기능, `LIVE_REQUIRED`는 구현과 fixture 검증은 완료됐지만 외부 계정 검증이 필요한 상태다.

| ID | 기능 | 소유권 | 구현 근거 | 검증 근거 | 상태 |
| --- | --- | --- | --- | --- | --- |
| F-01 | SEMI Agent 공개 계약 | SEMI | ProviderKit은 Agent gateway를 import하지 않음 | boundary verifier | OUTSIDE |
| F-02 | 대화 1회 직접 응답 | ProviderKit | `ProviderRuntime.execute`, `ProviderExecutionSupervisor` | direct streaming test | PASS |
| F-03 | ASA plan/work/review | SEMI/ASA | ProviderKit은 1-turn만 제공 | target/import graph | OUTSIDE |
| F-04 | 실제 text streaming | ProviderKit | HTTP/SSE decoder → `.textDelta` | fragmentation·normalization tests | PASS |
| F-05 | cancel·terminal exactly-once | ProviderKit | admission-ordered session start, execution reducer/session, single session registry with early ID release | immediate cancel, deadline, cleanup, reuse, shutdown, execute/shutdown interleaving tests | PASS |
| F-06 | bounded backpressure | ProviderKit | bounded mailbox, terminal reserved slot, text batch, bounded transport body buffer | core/runtime mailbox overflow, transport backpressure tests | PASS |
| F-07 | account readiness inspect | ProviderKit | `verificationRequired → inspect → ready`, credential contract | restart/readiness, invalid/no-op/source mismatch tests | PASS |
| F-08 | Soa external auth file | ProviderKit | `SecureRegularFileReader`, bounded async managed/installed Codex version resolver, Soa adapter | symlink·size·header injection·version fallback·wedged process tests, ASA live account/catalog/turn | PASS |
| F-09 | OpenRouter direct 호출 | ProviderKit | direct HTTP/SSE adapter | request/privacy/OAuth fixtures | LIVE_REQUIRED |
| F-10 | API key 계정 | ProviderKit + 호출자 저장 adapter | `ProviderCredentialVault` 주입; package는 secret 저장소를 제공하지 않음 | in-memory transaction tests | LIVE_REQUIRED |
| F-11 | OAuth 계정 | ProviderKit + Apple | OpenRouter PKCE broker, loopback session | RFC PKCE, callback/replay tests | LIVE_REQUIRED |
| F-12 | 복수 계정 격리 | ProviderKit | account ID keyed supervisor/vault/continuation | registration/revoke/continuation isolation tests | PASS |
| F-13 | model catalog·exact ID | ProviderKit | strict catalog parser, `ProviderModelID`, optional output-token limit | malformed/duplicate/limit catalog tests | LIVE_REQUIRED |
| F-14 | stage별 route | SEMI | `ProviderSelection` 값만 제공 | boundary verifier | OUTSIDE |
| F-15 | capability qualification | ProviderKit + SEMI | descriptor/catalog capability 상태 | strict decode tests | LIVE_REQUIRED |
| F-16 | structured output·reasoning 정책 | ProviderKit + caller | Provider별 output constraint, dialect별 reasoning 인코딩 또는 명시적 거부 | native/application-validated, reasoning policy tests | PASS |
| F-17 | tool call 정규화·선택 | ProviderKit | bounded argument accumulator, completed call only, explicit automatic/required/named policy | partial/malformed/oversize/tool-choice wire tests, ASA live strict calls | PASS |
| F-18 | tool 실행 권위 | SEMI | 실행 API 없음 | public API/boundary inspection | OUTSIDE |
| F-19 | usage 계측 | ProviderKit | normalized `ProviderUsage`, usage-only compatible chunk | malformed/overflow/usage-only tests | PASS |
| F-20 | privacy/data routing | ProviderKit + SEMI | request constraints → Provider wire | OpenRouter privacy fixture | PASS |
| F-21 | retry | ProviderKit | reducer의 same-route bounded pre-output retry 전이 | 401/429/opened-transport failure/visible-output tests | PASS |
| F-22 | cross-provider fallback | SEMI 향후 정책 | ProviderKit에서 금지 | request fixture·constraint validation | PASS |
| F-23 | 오류 정규화·redaction | ProviderKit | `ProviderFailure`, whitelisted URL/core/transport error mapping | secret/status/malformed JSON/unclassified error tests | PASS |
| F-24 | revoke·credential recovery | ProviderKit + 호출자 저장 adapter | staged transaction, compensation, reconciliation | crash-state/revoke/cancel race tests | LIVE_REQUIRED |
| F-25 | Provider/account/model 선택 값 | ProviderKit | open identifiers, immutable selection | round-trip/request tests | PASS |
| F-26 | 사용자 승인 | SEMI | readiness만 제공 | boundary verifier | OUTSIDE |
| F-27 | settings import fence | SEMI | shutdown/drain만 제공 | runtime shutdown tests | OUTSIDE |
| F-28 | 외부 local Agent process | SEMI | 구현 없음 | package graph | OUTSIDE |
| F-29 | MCP/CLI tool | SEMI | 구현 없음 | package graph | OUTSIDE |
| F-30 | 문서 artifact 저장 | SEMI | 구현 없음 | package graph | OUTSIDE |
| F-31 | 가짜 rechunk 제거 기반 | ProviderKit | native stream만 공개 | direct delta tests | PASS |
| F-32 | aichat subprocess 대체 기반 | ProviderKit | OpenRouter direct adapter | fixture PASS, live parity 필요 | LIVE_REQUIRED |
| F-33 | JSON 변환 축소 | ProviderKit | bounded `ProviderJSONValue` | deterministic round-trip tests | PASS |
| F-34 | 요청별 immutable selection | ProviderKit | `ProviderTurnRequest.selection` | active request/retry tests | PASS |
| F-35 | runtime shutdown/drain | ProviderKit; 제품 lifecycle은 SEMI | lifecycle admission fence, child join | concurrent shutdown tests | PASS |
| F-36 | release provenance | 저장소 | Git commit, `0.1.0` tag, GitHub Release, `Docs/COMPLETION_REPORT.md` | local clean extraction + GitHub Actions | PASS |

## 구조적 불변식

| 불변식 | 코드 경계 | 회귀 |
| --- | --- | --- |
| reducer는 부수 효과를 호출하지 않음 | Core account/execution reducer | reducer tests |
| 공유 가변 상태만 actor 격리 | runtime/account/execution/replay 및 호출자 vault | Thread Sanitizer |
| 동기 URLSession callback은 lock, `yield`는 lock 밖 | `HTTPTransport` | cancel/failure/sanitizer tests |
| terminal 이전 cleanup 및 종료 join | execution/account session은 `run` 종료까지 등록 유지, ID만 조기 해제 | cleanup ordering, immediate cancel, shutdown, interleaving tests |
| credential commit 이전 read-back | account session/credential contract | no-op activation/source mismatch tests |
| 취소가 commit보다 먼저 이기면 보상 삭제 | account session | non-cooperative stage/activation tests |
| unbounded input 없음 | Core values, HTTP/SSE/JSON/tool/mailbox/loopback listener | bound/overflow/listener tests |
| 공개 정책은 wire 반영 또는 명시적 거부 | output requirement·reasoning policy | native schema·reasoning policy tests |
| tool choice는 wire 반영 또는 명시적 거부 | `ProviderToolChoice`와 adapter | named/required encoding, Gemini fail-closed test |
| transport 종료 신호는 모든 경로에서 발화 | `HTTPTransport` 완료·무효화 delegate | cancel/invalidation/termination-order tests |
| 성장 입력에 대한 O(n²) scan 없음 | SSE/header cursor, direct account lookup, bounded amortized mailbox compaction | fragmented scan·account identity tests |
