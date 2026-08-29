# Architecture

## Product boundary

SEMIProviderKit의 단위는 “선택된 Provider·계정·모델로 실행하는 한 번의 모델 turn”이다.
반복 대화는 호출자가 assistant 응답을 history에 추가해 같은 계정·모델로 다음 turn을
요청하는 방식이며, package는 durable conversation state를 보관하지 않는다. 상위 제품의
planning, work/review route, tool 승인·실행, UI, durable run 복구는 포함하지 않는다.

```text
                  ┌─────────────────────┐
                  │  SEMIProviderCore   │
                  │ values/events/state │
                  │   pure reducers     │
                  └──────────▲──────────┘
                             │
             ┌───────────────┴───────────────┐
             │                               │
┌────────────┴────────────┐     ┌────────────┴────────────┐
│  SEMIProviderRuntime    │     │   SEMIProviderApple     │
│ actors/HTTP/SSE/effects │     │ PKCE/loopback OAuth UI  │
└─────────────────────────┘     └─────────────────────────┘
```

`Runtime → Core ← Apple`만 허용한다. Runtime과 Apple은 서로 import하지 않으며 세
product 모두 상위 앱, SwiftUI, Observation, TCA, tool executor를 import하지
않는다. 이 규칙은 `Scripts/verify-providerkit-boundaries.py`가 fail-closed로 검사한다.

## State, event, effect

상태 전이와 실패 경계가 있는 두 영역에만 reducer 구조를 적용한다.

| 영역 | State | Event | Effect | 실행 경계 |
| --- | --- | --- | --- | --- |
| account 등록 | `ProviderAccountState` | `ProviderAccountEvent` | `ProviderAccountEffect` | `ProviderAccountSupervisor` actor |
| turn 실행 | `ProviderExecutionState` | `ProviderExecutionEvent` | `ProviderExecutionEffect` | `ProviderExecutionSupervisor` actor |

Reducer는 동기 pure function이며 I/O를 호출하지 않는다. actor supervisor가 event를
직렬화하고 reducer가 반환한 effect를 async/await로 실행한다. 값 검증, Provider wire
codec, JSON/SSE parser처럼 공유 상태가 없는 코드는 struct/enum과 pure function으로
유지한다. 실행별 stream decoder는 한 execution actor 안에서 생성·소비·폐기되므로
`Sendable`이나 별도 actor가 아니다.

Runtime lifecycle, OAuth replay window, credential 저장은 공유 상태와 동시 호출이 실제로
존재해 actor로 격리한다. Runtime의 세 단계 lifecycle은 자원 drain과 직접 결합된 작은
admission fence라 별도 reducer로 복제하지 않는다. 즉 상태 전이 규칙이 복잡하고
effect를 명시적으로 검증해야 하는 두 영역에만 reducer를 적용한다.

Provider adapter 내부에서도 credential material 해석과 provider wire codec을 분리한다.
예를 들어 `CodexCredentialResolver`는 caller-owned `auth.json`의 안전한 읽기와 client
version 해석만 맡고, `OpenAIResponsesAdapter`는 Responses 요청·SSE codec만 맡는다.
따라서 외부 파일 경계의 보안·수명 정책이 Responses payload 구현에 역류하지 않는다.

UI 상태는 package 밖에서 `ProviderEventStream` 또는 `ProviderAccountEventStream`을
Observation/TCA action으로 투영한다. UI 종속 타입을 Core에 넣지 않는다.

## Execution flow

```text
caller-owned history + validated request
→ credential lease and account identity check
→ provider-native wire request
→ bounded HTTP transport
→ provider-native SSE 또는 unary JSON response parsing
→ normalized ProviderTurnEvent
→ child task and transport cleanup
→ exactly one terminal event
```

`.started`는 첫 HTTP transport가 열린 뒤 한 번만 발생한다. 재시도는 동일
Provider/account/model에서 첫 text 또는 tool output이 공개되기 전에만 허용한다.
terminal은 cleanup 뒤에 공개한다.

## Failure and recovery

- 계정 등록은 `staged → verified → active` 순서이며 실패·취소 시 staged credential을
  보상 삭제한다.
- `ProviderCredentialStore`는 저장 기술과 계정 transaction을 분리한다.
  `InMemoryProviderCredentialStore`는 권한 요청 없이 process lifetime만 제공하고,
  durable 저장은 호출자 구현으로 교체한다.
- activate 반환만 신뢰하지 않고 active record를 다시 읽어 identity와 source를 검증한다.
- 재시작 뒤 복원한 계정은 inspect 전까지 `.verificationRequired`다.
- `reconcileCredentials()`는 중단된 staged record를 정리하고 정리 실패를 report에 남긴다.
- revoke는 신규 실행을 막고 해당 계정의 실행을 cancel/join한 뒤 credential을 삭제한다.
- shutdown은 신규 작업 admission을 닫고 account/execution child task를 join한다.
- stream은 single-consumer이며 body, SSE, JSON, tool argument, mailbox와 loopback
  connection 모두 상한을 가진다.
- adapter는 response framing을 명시한다. SSE adapter만 stream parser를 사용하고,
  unary JSON adapter는 bounded body를 한 번 decode해 같은 normalized event reducer로
  전달한다. framing을 추측하거나 가짜 stream을 만들지 않는다.

## Complexity

성장 입력을 반복해서 처음부터 scan하는 O(n²) 경로는 유지하지 않는다.

- SSE와 HTTP header parser는 cursor/scanner를 사용해 입력을 선형 처리한다.
- credential과 account lookup은 ID keyed storage를 사용한다.
- account revoke는 account→execution 역색인으로 해당 계정의 `k`개 session만
  cancel/join한다. 전체 `n`개 session scan을 반복하지 않는다.
- mailbox는 head cursor를 이동하고 충분히 소비된 시점에만 amortized compaction한다.
- message/content adapter의 중첩 loop는 각 content를 정확히 한 번 방문하므로 전체
  content 수에 대해 O(n)이다.
- JSON tree walk는 O(nodes), deterministic key encoding과 model catalog 정렬은
  O(n log n)이며 각각 node/byte 또는 HTTP body 상한 안에서 수행한다.
- tool argument, request JSON과 response body는 명시적 byte/scalar 상한에서 실패한다.

작고 상한이 고정된 배열의 정렬·검증은 더 복잡한 index가 불변식과 오류 가능성을
증가시키는 경우 현재 구조를 유지한다. 성능 판단 기준은 구현 난이도가 아니라
입력 크기의 성장 가능성, 상한의 존재, 전체 복잡도다.

## Platform

`SEMIProviderCore`와 `SEMIProviderRuntime`은 iOS 18+와 macOS 15+를 지원한다.
`SEMIProviderApple`의 PKCE·callback parser는 두 Apple platform에서 제공하지만,
AppKit으로 browser를 여는 loopback OAuth session은 macOS 전용이다. iOS host는
자신의 authorization session을 `ProviderAuthorizationSession`으로 주입해야 하며,
ProviderKit이 browser UI나 callback scheme을 대체하지 않는다. Security는 PKCE용
CSPRNG에만 사용한다.

Codex wire version은 `CodexClientVersion`이 패키지 상수로 선언한다.
`OpenAIResponsesAdapter`는 Responses 요청·SSE codec만 맡는다. 버전 결정은 인접 metadata,
설치 앱, PATH, subprocess를 읽지 않으므로 같은 입력은 호스트 상태와 무관하게 같은 요청을 만든다.
