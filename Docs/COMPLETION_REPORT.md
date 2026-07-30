# SEMIProviderKit Completion Report

## 제품 상태

macOS 26 전용 Provider 실행 package의 account lifecycle, direct model turn,
streaming, retry·cancel·shutdown, credential recovery와 OAuth 경계는 구현·검증됐다.
초기 공개 버전은 `0.1.0`이며 GitHub Actions와 로컬 clean extraction을 모두 통과한
tagged commit만 release로 게시한다.

ProviderKit이 소유하지 않는 Agent orchestration, tool 실행 권위, UI, durable run
저장은 의도적으로 포함하지 않는다. 입력·출력·산출물 소유권은
`Docs/INTERFACE_CONTRACT.md`에 고정했다.

## Canonical source와 release identity

- canonical source: `https://github.com/axiom-orient/SEMIProviderKit`
- Git branch: `main`
- commit: release tag가 가리키는 Git commit
- release tag: `0.1.0`
- release 원칙: clean working tree의 검증된 commit만 tag하고 해당 commit에서 archive 생성

Git tag와 GitHub Release가 고정된 source identity를 제공한다. 이전의 수동 source
identifier와 repository-internal checksum 계층은 Git tree와 중복되어 제거했다.

## 주요 수정 사항

- 루트 문서를 짧은 진입점으로 갱신하고 architecture, interface contract, functional
  matrix, completion evidence를 `Docs/`로 모았다.
- 입력은 immutable request와 caller-owned vault, 출력은 bounded single-consumer event
  stream, 저장 artifact는 caller-owned라는 계약을 명시했다.
- concrete Keychain/평문 vault와 migration·legacy raw-value decoder를 제공하지 않는
  현재 저장 경계를 문서와 코드에 일치시켰다.
- macOS 26 밖의 FoundationNetworking, Glibc, portable SHA-256, AppKit/Network 부재용
  fallback과 해당 조건부 테스트를 제거했다. Security 사용은 PKCE CSPRNG로 제한된다.
- 성장 입력의 O(n²) scan을 허용하지 않는 cursor, direct lookup, amortized mailbox
  compaction과 모든 input bound를 architecture 문서에 추적했다.
- `ProviderTurnRequest.toolChoice`의 모든 공개 정책이 Codable 왕복에서 보존되도록
  구현과 회귀를 완성했다.
- Soa embedded Codex version probe를 async 경계로 옮기고 5초 timeout, 호출자
  cancellation, process cleanup과 성공 결과 memoization을 구현했다.
- SwiftPM·Xcode 생성물, sanitizer·coverage 결과, IDE 개인 상태, macOS metadata,
  로그·임시·로컬 환경 파일을 `.gitignore`에서 배제했다.

## 실행한 검증과 실제 결과

- warnings-as-errors debug build/test: 87/87 통과
- warnings-as-errors release build/test: 87/87 통과
- GitHub Actions: macOS 26 runner의 현재 Xcode에서 format, architecture boundary,
  warnings-as-errors debug·release test 검증
- Thread Sanitizer: 87/87 통과, race 보고 없음
- Address Sanitizer: 87/87 통과
- `swift-format lint -r -s Sources Tests Package.swift`: 위반 없음
- product·target·import·source boundary verifier: 통과
- Markdown local link 검증: 통과
- ASA consumer external-scratch gate: XCTest 100/100 + Swift Testing 2/2 통과

## Clean extraction 검증

Git이 추적할 source만 새 임시 디렉터리로 추출하고 별도 scratch에서 architecture
boundary와 warnings-as-errors debug·release test 87/87을 통과했다. GitHub가 release
tag에서 생성하는 source archive는 게시 후 다시 확인한다.

## 플랫폼 제약으로 실행하지 못한 항목

- OpenAI, Anthropic, Gemini, OpenRouter와 API-key Provider의 실제 계정별 live
  qualification은 credential이 없어 실행하지 못했다.
- 실제 OpenRouter browser 승인과 authorization-code 교환은 실행하지 못했다.
- `swift-tools-version: 6.2`는 유지하지만 Swift 6.2 도구체인 전용 CI는 실행하지
  않았다.

## 알려진 잔여 위험

- Soa private endpoint와 local auth schema는 안정된 공개 API가 아니다.
- API-key Provider의 모델별 tools, structured output, reasoning 허용 범위는 live
  qualification 전에는 fixture와 Provider 문서 수준이다.
- caller가 주입하는 `ProviderCredentialVault`의 내구성·보안은 package 밖의 책임이며
  실제 제품 vault는 동일 contract로 별도 검증해야 한다.
- transport backpressure는 무한 buffering 대신 명시적 terminal failure를 선택한다.
- 관리된 `version.json`이 없고 embedded Codex가 응답하지 않으면 최초 turn의 terminal
  공개가 최대 5초 늦어질 수 있다.

현재 접근 가능한 환경에서 저장소 코드로 해결할 수 있는 알려진 핵심 결함은 남아 있지
않다. 계정이 필요한 live qualification 제약은 공개 release note에도 명시한다.
