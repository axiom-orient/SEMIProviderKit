# Completion Report

## Scope

SEMIProviderKit은 macOS 26에서 선택된 provider·account·model로 한 번의 model turn을
실행하는 Swift package다. account lifecycle, direct streaming, retry, cancellation,
shutdown, credential recovery와 OAuth boundary를 소유한다. Agent orchestration, UI,
tool 실행 권위, cross-provider fallback, durable run state는 호출자 제품의 책임이다.

현재 subscription provider의 공개 ID와 protocol family는 각각 `codex`와
`codex_responses`다.

## Current Candidate

- subscription provider의 공개 ID와 protocol family는 각각 `codex`와
  `codex_responses`다.
- Codex credential file 해석은 `CodexCredentialResolver`가 소유하고, Responses wire
  codec은 `OpenAIResponsesAdapter`가 소유한다.
- OpenAI·Gemini의 server-side continuation은 명시적 data collection·retention opt-in이
  있을 때만 저장과 재사용을 허용한다. Codex subscription endpoint는 해당 capability를
  제공하지 않아 fail-closed한다.
- credential material의 description/debug description은 경로와 secret을 노출하지 않는다.
- OAuth callback 화면과 OpenRouter application title은 `SEMI` 이름만 사용한다.

## Verification Record

이 문서는 current candidate에 대해 실제로 실행한 결과만 기록한다. 상세 gate와 release
판정은 [RELEASE_READINESS.md](RELEASE_READINESS.md)를 따른다.

- 2026-08-01: warnings-as-errors debug·release build/test, TSAN, ASAN, format, source
  boundary 검사 통과 (3개 suite, 총 92개 test).
- 2026-08-01: 새 `git archive` 추출본에서 warnings-as-errors debug·release build/test와
  source boundary 검사를 통과했다 (3개 suite, 총 91개 test). 별도 SwiftPM consumer가 세
  public product를 import·build·실행했다.
- 2026-08-01: 공개 SwiftPM 소비자에서 Codex 등록·catalog·text·structured output·tool
  call·즉시 cancel·revoke와 missing-credential compensation을 실제 계정으로 통과.
- 2026-08-01: Codex continuation은 실제 endpoint의 거부를 재현했고, 수정 뒤 network 전
  `capabilityMismatch` 차단을 통과.
- 2026-08-01: Luna subscription에서 caller-owned history를 포함한 Codex turn 3회를
  연속 완료했다. `maximumOutputTokens`는 endpoint의 HTTP 400 재현 뒤 network 전
  `capabilityMismatch`로 명시 차단했다.
- 2026-08-02: 임시 외부 SwiftPM consumer가 existing Codex auth reference로
  `register → models(8) → exact text streaming turn → revoke`를 통과했다. 존재하지 않는
  auth reference는 terminal failure와 빈 `accounts()`로 staged credential 보상 제거를
  확인했다. credential 내용과 응답 본문은 출력하지 않았다.

## Residual External Scope

- Codex continuation은 실제 endpoint의 `invalid_request` 관찰에 따라 unsupported로
  분류했다. package는 이를 network 전 `capabilityMismatch`로 차단한다.
- OpenAI API key, Anthropic, Gemini, OpenRouter와 다른 API-key provider의 live
  qualification은 account·model별로 독립적이다.
- caller가 제공하는 durable `ProviderCredentialStore`의 persistence·security는 package
  밖의 책임이다.

## Release Boundary

이 문서는 source의 검증 기록이며 release identity가 아니다. 게시 전에는 version을
결정하고, clean working tree의 exact commit을 고정한 뒤 새 archive에서 검증을 다시
실행해야 한다. 이후 tag·push·GitHub Release 게시에는 별도의 명시적 승인이 필요하다.
