# Completion Report

## Scope

SEMIProviderKit은 macOS 26에서 선택된 provider·account·model로 한 번의 model turn을
실행하는 Swift package다. account lifecycle, direct streaming, retry, cancellation,
shutdown, credential recovery와 OAuth boundary를 소유한다. Agent orchestration, UI,
tool 실행 권위, cross-provider fallback, durable run state는 호출자 제품의 책임이다.

현재 subscription provider의 공개 ID와 protocol family는 각각 `codex`와
`codex_responses`다. compatibility wrapper는 제공하지 않는다.

## Current Candidate

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
  boundary 검사 통과 (각 test suite 90개).
- 2026-08-01: 공개 SwiftPM 소비자에서 Codex 등록·catalog·text·structured output·tool
  call·즉시 cancel·revoke와 missing-credential compensation을 실제 계정으로 통과.
- 2026-08-01: Codex continuation은 실제 endpoint의 거부를 재현했고, 수정 뒤 network 전
  `capabilityMismatch` 차단을 통과.

## Residual External Scope

- Codex continuation은 실제 endpoint의 `invalid_request` 관찰에 따라 unsupported로
  분류했다. package는 이를 network 전 `capabilityMismatch`로 차단한다.
- OpenAI API key, Anthropic, Gemini, OpenRouter와 다른 API-key provider의 live
  qualification은 account·model별로 독립적이다.
- caller가 제공하는 durable `ProviderCredentialStore`의 persistence·security는 package
  밖의 책임이다.
