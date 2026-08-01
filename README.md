# SEMIProviderKit

macOS 26에서 Provider·계정·모델을 선택해 한 번의 모델 turn을 직접 실행하는
Swift 6 package다. 상태 전이는 pure reducer, 공유 가변 상태는 actor, 외부 작업은
명시적 effect와 protocol 경계로 분리한다.

Agent orchestration, UI, tool 실행 권한, cross-provider fallback, durable Agent state는
이 package의 책임이 아니다.

## Products

| Product | 책임 |
| --- | --- |
| `SEMIProviderCore` | 검증된 값, 상태·event·effect, pure reducer, bounded event stream |
| `SEMIProviderRuntime` | account/execution actor, Provider wire codec, HTTP/SSE, retry·cancel·recovery |
| `SEMIProviderApple` | CryptoKit/Security 기반 PKCE와 AppKit/Network loopback OAuth |

의존 방향은 `Runtime → Core ← Apple`이며 Runtime과 Apple은 서로 의존하지 않는다.

## Integration

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
  // started, textDelta, toolCall, terminal
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

기본 subscription provider의 공개 ID는 `codex`다. 현재 source는 compatibility
wrapper를 제공하지 않으며, 배포 integration은 검증된 tag를 사용하고 개발 중인 source는
local package dependency로 연결한다.

## Repository

| 경로 | 내용 |
| --- | --- |
| [`Docs/`](Docs/README.md) | 설계, 인터페이스 계약, 기능 추적, 완료 근거 |
| [`Sources/`](Sources/) | 세 product의 canonical source |
| [`Tests/`](Tests/) | Core·Runtime·Apple 회귀 테스트 |
| [`Scripts/`](Scripts/) | product·target·import 경계 검증 |
| [`Package.swift`](Package.swift) | 유일한 build manifest |
| [`AGENTS.md`](AGENTS.md) | 로컬 검증·릴리스 작업 규칙 |
| [`.gitignore`](.gitignore) | 재생성·로컬 전용 파일 제외 규칙 |
| [`LICENSE`](LICENSE) | MIT 라이선스 |

## Verification

```bash
swift build -Xswiftc -warnings-as-errors
swift test --parallel -Xswiftc -warnings-as-errors
python3 Scripts/verify-providerkit-boundaries.py
```

Git commit이 canonical source identity다. GitHub Actions나 GitHub CI는 사용하지
않으며, 배포는 로컬에서 검증한 clean working tree의 commit에 semantic version tag를
붙인다. archive가 필요하면 해당 commit에서 생성한다. build cache, Xcode·IDE 개인
상태, sanitizer·coverage 결과, 로그와 로컬 환경 파일은 `.gitignore`로 저장소에서
배제한다. `Package.resolved`는 향후 생성되면 dependency 변경을 검토할 수 있도록
추적한다.

지원·검증 대상은 macOS 26과 Swift 6.2 이상이다. 상세한 입력·출력·산출물 소유권은
[`Docs/INTERFACE_CONTRACT.md`](Docs/INTERFACE_CONTRACT.md), 최종 검증 결과와 제약은
[`Docs/COMPLETION_REPORT.md`](Docs/COMPLETION_REPORT.md), 현재 릴리스 준비 상태는
[`Docs/RELEASE_READINESS.md`](Docs/RELEASE_READINESS.md)에 있다.

## License

SEMIProviderKit is available under the [MIT License](LICENSE).
