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
.package(
  url: "https://github.com/axiom-orient/SEMIProviderKit.git",
  from: "0.1.0"
)
```

```swift
import SEMIProviderCore
import SEMIProviderRuntime

let runtime = ProviderRuntime(credentialVault: appCredentialVault)
let stream = await runtime.execute(turnRequest)

for await event in stream {
  // started, textDelta, toolCall, terminal
}
```

호출자는 `ProviderCredentialVault`를 구현하고 수명 주기 종료 시
`await runtime.shutdown()`을 호출한다. package는 Keychain이나 평문 secret 저장소를
제공하지 않는다.

## Repository

| 경로 | 내용 |
| --- | --- |
| [`Docs/`](Docs/README.md) | 설계, 인터페이스 계약, 기능 추적, 완료 근거 |
| `Sources/` | 세 product의 canonical source |
| `Tests/` | Core·Runtime·Apple 회귀 테스트 |
| `Scripts/` | product·target·import 경계 검증 |
| `Package.swift` | 유일한 build manifest |

## Verification

```bash
swift build -Xswiftc -warnings-as-errors
swift test --parallel -Xswiftc -warnings-as-errors
python3 Scripts/verify-providerkit-boundaries.py
```

Git commit이 canonical source identity다. 배포는 clean working tree의 commit에 semantic
version tag를 붙이고, archive가 필요하면 해당 commit에서 생성한다. build cache,
Xcode·IDE 개인 상태, sanitizer·coverage 결과, 로그와 로컬 환경 파일은 `.gitignore`로
저장소에서 배제한다. `Package.resolved`는 향후 생성되면 dependency 변경을 검토할 수
있도록 추적한다.

지원·검증 대상은 macOS 26과 Swift 6.2 이상이다. 상세한 입력·출력·산출물 소유권은
[`Docs/INTERFACE_CONTRACT.md`](Docs/INTERFACE_CONTRACT.md), 최종 검증 결과와 제약은
[`Docs/COMPLETION_REPORT.md`](Docs/COMPLETION_REPORT.md)에 있다.

## License

SEMIProviderKit is available under the [MIT License](LICENSE).
