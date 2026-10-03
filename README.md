# SEMIProviderKit

iOS 18+와 macOS 15+에서 Provider·계정·모델을 선택해 모델 turn을 직접 실행하는 Swift 6 package다.
반복 대화는 호출자가 이전 assistant 응답을 포함한 history를 다음 immutable request에
다시 넣어 실행한다. 상태 전이는 pure reducer, 공유 가변 상태는 actor, 외부 작업은
명시적 effect와 protocol 경계로 분리한다.

Agent orchestration, UI, tool 실행 권한, cross-provider fallback, durable Agent state는
이 package의 책임이 아니다.

## Products

| Product | 책임 |
| --- | --- |
| `SEMIProviderCore` | 검증된 값, 상태·event·effect, pure reducer, bounded event stream |
| `SEMIProviderRuntime` | account/execution actor, Provider wire codec, HTTP/SSE, retry·cancel·recovery |
| `SEMIProviderApple` | CryptoKit/Security 기반 PKCE와 callback parser, macOS loopback OAuth |

의존 방향은 `Runtime → Core ← Apple`이며 Runtime과 Apple은 서로 의존하지 않는다.

## Integration

배포 integration에는 검증된 semantic-version tag를 사용한다. 개발 중인 source는
다음처럼 local dependency로 검증한다.

```swift
// Package.swift
.package(path: "../SEMIProviderKit")
```

```swift
import SEMIProviderCore
import SEMIProviderRuntime

let credentialStore = InMemoryProviderCredentialStore()
let runtime = ProviderRuntime(credentialStore: credentialStore)

for await event in await runtime.register(registrationRequest) {
  // staging, verifying, activating, ready or failure
}

let stream = await runtime.execute(turnRequest)

for await event in stream {
  // started, textDelta, reasoningDelta, toolCall, terminal
}
```

`InMemoryProviderCredentialStore`는 영구 저장·권한 요청 없이 process lifetime 동안만
credential을 보관한다. 앱 재시작 뒤에도 계정을 유지해야 하면
`ProviderCredentialStore`를 구현해 주입한다. 어느 방식을 쓰든 수명 주기 종료 시
`await runtime.shutdown()`을 호출한다.

`ProviderContinuation`은 provider 서버의 이전 응답/interaction 상태를 다시 쓰는
기능이다. 따라서 기본 no-retention 정책에서는 거부되며, continuation을 생성하거나
사용할 때는 `dataCollection: .allow`와 `requiresZeroDataRetention: false`를 명시해야
한다.

기본 subscription provider의 공개 ID는 `codex`다.

내장 registry는 Codex·OpenAI Responses, OpenAI-compatible Chat Completions,
Anthropic Messages, Gemini Interactions, OpenRouter, xAI, DeepSeek, Qwen, Kimi,
Z.AI, MiniMax와 Antigravity Cloud Code를 명시적으로 구분한다. Antigravity는
bearer credential과 non-secret `project-id` account option이 필요한 unary JSON
dialect다. 검증된 account-inspection·model-catalog endpoint가 없으므로 그 두 control
operation은 성공처럼 처리하지 않고 `capabilityMismatch`로 거부한다. 실제 제공자 호출은
각 계정·모델·권한 조합으로 별도 qualification이 필요하다.

Codex의 반복 대화는 server-side `ProviderContinuation`이 아니라 caller-owned history를
사용한다. 매 turn의 terminal `.textDelta`를 모아 `.assistant` message로 추가하고, 다음
`.user` message와 함께 새 request ID로 `execute`한다. Codex가 지원하지 않는
`maximumOutputTokens`와 `ProviderContinuation`은 network 전 `capabilityMismatch`로
거부된다.

## Repository

| 경로 | 내용 |
| --- | --- |
| [`Docs/`](Docs/README.md) | 설계, 인터페이스 계약, 기능 범위 |
| [`Sources/`](Sources/) | 세 product의 canonical source |
| [`Tests/`](Tests/) | Core·Runtime·Apple 회귀 테스트 |
| [`Scripts/`](Scripts/) | 유일한 local verify·clean 진입점과 경계 검증 |
| [`Package.swift`](Package.swift) | 유일한 build manifest |
| [`AGENTS.md`](AGENTS.md) | 로컬 검증·릴리스 작업 규칙 |
| [`.gitignore`](.gitignore) | 재생성·로컬 전용 파일 제외 규칙 |
| [`LICENSE`](LICENSE) | MIT 라이선스 |

## Verification

```bash
Scripts/verify.sh
```

Git commit이 canonical source identity다. GitHub Actions나 GitHub CI는 사용하지
않으며, 배포는 로컬에서 검증한 clean working tree의 commit에 semantic version tag를
붙인다. release candidate는 해당 exact commit을 `git archive`로 새 directory에 추출해
동일한 build·test·boundary 검사를 통과해야 한다. archive가 필요하면 해당 commit에서
생성한다. build cache, Xcode·IDE 개인
상태, sanitizer·coverage 결과, 로그와 로컬 환경 파일은 `.gitignore`로 저장소에서
배제한다. `Package.resolved`는 향후 생성되면 dependency 변경을 검토할 수 있도록
추적한다.

지원·검증 대상은 iOS 18+, macOS 15, Swift 6.2 이상이다. 상세한 입력·출력·산출물 소유권은
[`Docs/INTERFACE_CONTRACT.md`](Docs/INTERFACE_CONTRACT.md)에 있다.

## 공개 경계

소스 공개에는 `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `Docs/`,
`LICENSE`만 포함한다. SwiftPM build cache, Xcode 개인 상태, sanitizer·coverage
결과, 로그와 local environment는 배포 입력이 아니다. 배포 후보는 같은 clean
commit을 `git archive`로 추출해 local build·test·boundary gate를 다시 통과한
경우에만 검토하며, GitHub Actions와 원격 CI는 증거로 사용하지 않는다.

## License

SEMIProviderKit is available under the [MIT License](LICENSE).

## GitHub 배포 분류

SEMIProviderKit의 주 제품은 개발자가 import해 조합하는 Swift provider SDK이므로 canonical 조직은 [`axiom-orient`](https://github.com/axiom-orient)다. 샘플과 검증 실행 파일은 패키지의 보조 표면이다.
