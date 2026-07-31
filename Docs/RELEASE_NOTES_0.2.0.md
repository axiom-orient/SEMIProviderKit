# SEMIProviderKit 0.2.0

`0.2.0`은 credential 저장 경계를 명확히 하고 account revoke 비용을 활성 실행 수에
비례하도록 개선한 pre-1.0 release다.

## Changes

- `ProviderCredentialStore` protocol로 caller-owned credential 저장 경계를 제공한다.
- `InMemoryProviderCredentialStore`를 기본 선택지로 제공한다. 사용자 승인이나 영구
  저장 없이 process lifetime 동안 credential을 보관한다.
- account별 execution 역색인으로 revoke가 다른 account의 execution을 scan하지 않는다.
- actor 안에 격리된 stream decoder에서 불필요한 `@unchecked Sendable` 계약을 제거했다.

## Breaking changes

`0.1.0` consumer는 credential store protocol 이름과 `ProviderRuntime` initializer의
`credentialStore:` label에 맞춰 source를 갱신해야 한다. 이전 이름을 유지하는 호환
wrapper는 제공하지 않는다.

## Verification

macOS 26, Swift 6.3.3에서 warnings-as-errors debug/release, 89개 test,
Thread Sanitizer, Address Sanitizer, clean source archive, 독립 SwiftPM consumer를
검증했다. 실제 Soa account 등록·model 조회·text turn·revoke 실패 경로와 sibling ASA
통합 흐름도 통과했다.

## Known limitations

- Soa endpoint와 local auth schema는 안정된 공개 API가 아니다.
- API-key Provider와 OpenRouter OAuth의 실제 계정별 live qualification은 이 release
  검증 환경에서 실행하지 못했다.
- `InMemoryProviderCredentialStore`는 의도적으로 process 종료 시 credential을
  잃는다. 영속 저장이 필요하면 consumer가 `ProviderCredentialStore`를 구현해야 한다.
