# Release 0.2.0

## Status

`0.2.0`은 준비 중이며 아직 게시하지 않는다. 현재 판정은 `NO-GO`다. 최종 commit을
`origin/main`에 push하고 그 commit의 GitHub Actions가 통과하기 전에는 tag나 GitHub
Release를 만들지 않는다.

기준 release는 `0.1.0`
(`17529125600f7156b3fda16497354562b2296887`)이다. `0.2.0`은 credential 공개 계약을
명확히 하는 pre-1.0 minor breaking release다.

## User-visible changes

- credential 경계는 저장 기술을 암시하지 않는 `ProviderCredentialStore`와
  `credentialStore:` initializer label을 사용한다.
- `InMemoryProviderCredentialStore`를 제공한다. 영구 저장이나 사용자 권한 요청 없이
  process lifetime 동안 API key, OAuth-derived key, 외부 auth-file reference를
  관리한다.
- account revoke는 account→execution 역색인으로 해당 계정의 실행만 cancel/join한다.
- execution actor 안에서만 쓰는 mutable stream decoder는 동시성 계약에서 제외했다.

호환 wrapper는 제공하지 않는다. `0.1.0` consumer는 protocol 이름과
`ProviderRuntime` initializer label을 새 계약에 맞춰 source update해야 한다.

## Verification evidence

- warnings-as-errors debug/release: 89/89 tests 통과
- Thread Sanitizer와 Address Sanitizer: 각각 89/89 통과
- format, product/target/import/source boundary, Markdown link: 통과
- public symbol graph: 새 credential store API 존재, 제거한 공개 이름 부재
- commit source의 clean `git archive`: debug/release 각각 89/89 통과
- 독립 public SwiftPM consumer: compile·run 통과
- 실제 Soa:
  - 존재하지 않는 auth file은 `authentication_failed` 뒤 staged record를 보상 삭제
  - 실제 auth file로 account 등록과 model 8개 조회
  - `gpt-5.6-terra` text turn 완료
  - revoke 뒤 같은 account 실행은 `account_unavailable`
- sibling ASA:
  - release build 통과
  - XCTest 100/100, Swift Testing 2/2 통과
  - actual provider status `authenticationConfigured=true`, `available=true`
  - read-only analyzed flow가 `assurance=reviewed`로 완료

## Publish gates

- [ ] final candidate working tree가 clean하다.
- [ ] `swift format lint --strict --recursive Package.swift Sources Tests`가 통과한다.
- [ ] `python3 Scripts/verify-providerkit-boundaries.py`가 통과한다.
- [ ] warnings-as-errors debug/release tests가 통과한다.
- [ ] final commit을 `origin/main`에 push한다.
- [ ] 그 exact commit의 GitHub Actions가 성공한다.
- [ ] `0.2.0` annotated tag가 그 exact commit을 가리킨다.
- [ ] tag source archive를 새 scratch에서 다시 build/test한다.
- [ ] [사용자용 release notes](RELEASE_NOTES_0.2.0.md)가 최종 API와 잔여 위험을
      정확히 설명한다.

## Publish sequence

```bash
git push origin main
candidate_sha=$(git rev-parse HEAD)
gh run list \
  --repo axiom-orient/SEMIProviderKit \
  --commit "$candidate_sha" \
  --json headSha,status,conclusion,url
git tag -a 0.2.0 -m "SEMIProviderKit 0.2.0"
git push origin 0.2.0
release_dir=$(mktemp -d)
git archive \
  --format=tar.gz \
  --prefix=SEMIProviderKit-0.2.0/ \
  --output="$release_dir/SEMIProviderKit-0.2.0-source.tar.gz" \
  0.2.0
(
  cd "$release_dir"
  shasum -a 256 SEMIProviderKit-0.2.0-source.tar.gz \
    > SEMIProviderKit-0.2.0-source.tar.gz.sha256
)
gh release create 0.2.0 \
  --repo axiom-orient/SEMIProviderKit \
  --verify-tag \
  --title "SEMIProviderKit 0.2.0" \
  --notes-file Docs/RELEASE_NOTES_0.2.0.md \
  "$release_dir/SEMIProviderKit-0.2.0-source.tar.gz" \
  "$release_dir/SEMIProviderKit-0.2.0-source.tar.gz.sha256"
```

Tag push 전에는 `git rev-parse HEAD`, `git rev-parse origin/main`과 성공한 workflow의
`headSha`가 모두 같아야 한다. 별도 source archive는 tagged commit의 `git archive`로
생성하고 checksum은 archive 밖에 둔다. 위 임시 release directory는 게시와 asset
다운로드 검증이 끝난 뒤 삭제한다.

## Stop and rollback

다음 중 하나면 게시를 중단한다.

- final commit CI가 실패하거나 다른 SHA에서만 성공했다.
- clean archive가 build/test되지 않는다.
- public consumer 또는 ASA integration이 새 source에서 compile되지 않는다.
- 실제 credential, terminal cleanup, revoke 격리에서 회귀가 확인된다.
- 문서의 API와 symbol graph가 일치하지 않는다.

게시 전 문제는 tag를 만들지 않고 수정 commit으로 해결한다. 게시 뒤 회귀는 tag를
이동하거나 기존 archive를 교체하지 않는다. GitHub Release에 영향과 권장 pin
(`0.1.0`)을 명시하고 수정 release를 새 version으로 낸다. credential/API 회귀는
`0.1.0` pin, performance-only 역색인 회귀는 새 patch release가 기본 복구 경로다.

## Known external risks

- Provider별 tools, structured output, reasoning 범위는 계정·모델별 live qualification이
  계속 필요하다.
- Soa endpoint와 외부 auth schema는 안정된 공개 API가 아니다.
- persistent credential store의 내구성·보안은 이를 구현하는 consumer 책임이다.
- Swift 6.2 전용 toolchain CI는 없고 macOS 26 current Xcode와 Swift 6.3.3에서
  검증했다.
