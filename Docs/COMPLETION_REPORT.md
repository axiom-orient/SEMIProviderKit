# SEMIProviderKit Completion Report

## 제품 상태

macOS 26 전용 Provider 실행 package의 account lifecycle, direct model turn,
streaming, retry·cancel·shutdown, credential recovery와 OAuth 경계는 구현·검증됐다.
공개된 버전은 `0.1.0`이고 현재 source는 credential API를 명확히 한 `0.2.0`
후보다. GitHub Actions와 GitHub CI는 사용하지 않는다. 로컬 clean extraction을
통과한 exact commit만 새 release로 게시한다.

ProviderKit이 소유하지 않는 Agent orchestration, tool 실행 권위, UI, durable run
저장은 의도적으로 포함하지 않는다. 입력·출력·산출물 소유권은
`Docs/INTERFACE_CONTRACT.md`에 고정했다.

## Canonical source와 release identity

- canonical source: `https://github.com/axiom-orient/SEMIProviderKit`
- Git branch: `main`
- published commit: `17529125600f7156b3fda16497354562b2296887`
- published release tag: `0.1.0`
- candidate identity: 이 보고서를 포함하는 최종 Git commit
- candidate release: `0.2.0` (미게시)
- release 원칙: clean working tree의 검증된 commit만 tag하고 해당 commit에서 archive 생성

Git tag와 GitHub Release가 고정된 source identity를 제공한다. 이전의 수동 source
identifier와 repository-internal checksum 계층은 Git tree와 중복되어 제거했다.

## 주요 수정 사항

- 루트 문서를 짧은 진입점으로 갱신하고 architecture, interface contract, functional
  matrix, completion evidence를 `Docs/`로 모았다.
- 입력은 immutable request와 caller-owned store, 출력은 bounded single-consumer event
  stream, 저장 artifact는 caller-owned라는 계약을 명시했다.
- 저장 기술을 뜻하는 `ProviderCredentialStore` 경계와 권한·영구 저장 없이 바로 쓸 수
  있는 actor 기반 `InMemoryProviderCredentialStore`를 제공한다.
- account revoke가 모든 execution을 scan하지 않도록 account→execution 역색인을
  추가했고, 다른 계정의 실행을 건드리지 않는 회귀를 고정했다.
- execution actor 안에서만 쓰는 mutable stream decoder의 허위 `Sendable` 계약과
  `@unchecked Sendable`을 제거했다.
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

- warnings-as-errors debug build/test: 89/89 통과
- warnings-as-errors release build/test: 89/89 통과
- Thread Sanitizer: 89/89 통과, race 보고 없음
- Address Sanitizer: 89/89 통과
- `swift-format lint -r -s Sources Tests Package.swift`: 위반 없음
- product·target·import·source boundary verifier: 통과
- public symbol graph: 새 credential store 이름과 initializer label 존재, 제거한 공개
  이름 부재
- SwiftPM API 진단: `0.1.0` 대비 공개 credential 계약 2개와 package-scoped
  initializer·decoder 계약을 합친 예상된 breaking change 10개 확인
- 독립 SwiftPM release consumer: public `ProviderCredentialStore`,
  `InMemoryProviderCredentialStore`, `ProviderRuntime` compile·run 통과
- 실제 process-lifetime store와 Soa 경계:
  - missing auth file은 `authentication_failed` 뒤 staged credential 보상 삭제
  - 실제 auth file로 등록, model 8개 조회, `gpt-5.6-terra` text turn 완료
  - revoke 뒤 같은 account 실행은 `account_unavailable`
- sibling ASA current source:
  - 중복 credential wrapper를 제거하고 public in-memory store를 직접 사용
  - warnings-as-errors release build, XCTest 100/100, Swift Testing 2/2 통과
  - actual provider status와 read-only analyzed flow(`assurance=reviewed`) 통과
- 저장소의 자동 workflow를 제거했고 로컬 검증 결과만 release gate로 사용한다.

## Clean extraction 검증

최종 후보 source만 새 임시 디렉터리로 복사하고 기존 `.build`와 작업 디렉터리 밖의
별도 scratch에서 architecture boundary와 warnings-as-errors debug·release test
89/89을 통과했다. Git commit 뒤에는 같은 commit의 `git archive`로 다시 확인하고,
GitHub가 release tag에서 생성하는 source archive는 게시 후 확인한다.

## 플랫폼 제약으로 실행하지 못한 항목

- OpenAI, Anthropic, Gemini, OpenRouter와 API-key Provider의 실제 계정별 live
  qualification은 credential이 없어 실행하지 못했다.
- 실제 OpenRouter browser 승인과 authorization-code 교환은 실행하지 못했다.
- `swift-tools-version: 6.2`는 유지하지만 Swift 6.2 도구체인은 별도로 실행하지
  않았다.
- `0.2.0` tag와 게시된 source archive는 아직 존재하지 않는다.
- 첫 live harness가 임의의 catalog 첫 모델과 64-token 제한으로 HTTP 400을 받았다.
  기존 live-qualified 모델과 제품 기본 output 계약으로 교정한 뒤 통과했으므로
  product failure가 아니라 harness failure로 분류했다.

## 알려진 잔여 위험

- Soa private endpoint와 local auth schema는 안정된 공개 API가 아니다.
- API-key Provider의 모델별 tools, structured output, reasoning 허용 범위는 live
  qualification 전에는 fixture와 Provider 문서 수준이다.
- caller가 주입하는 `ProviderCredentialStore`의 내구성·보안은 package 밖의 책임이며
  실제 제품 store는 동일 contract로 별도 검증해야 한다.
- `InMemoryProviderCredentialStore`는 의도적으로 process 종료 시 credential을
  잃는다.
- credential boundary의 공개 이름이 변경됐으므로 기존 `0.1.0` consumer는 `0.2.0`
  채택 시 source update가 필요하다. 호환 wrapper는 두지 않는다.
- transport backpressure는 무한 buffering 대신 명시적 terminal failure를 선택한다.
- 관리된 `version.json`이 없고 embedded Codex가 응답하지 않으면 최초 turn의 terminal
  공개가 최대 5초 늦어질 수 있다.

현재 접근 가능한 로컬 환경에서 저장소 코드로 해결할 수 있는 알려진 핵심 결함은 남아
있지 않다. 실제 Provider별 추가 qualification은 지속 과제다. 로컬 검증을 통과한
exact commit과 tag/archive의 동일성을 확인하기 전에는 `0.2.0`을 게시 완료로
표시하지 않는다.
