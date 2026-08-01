# Release Readiness

## Candidate Scope

- public subscription provider identity를 `codex`와 `codex_responses`로 정리
- ARA와 이전 release 문서·parity 문서 제거
- OpenAI·Gemini continuation storage opt-in과 Codex fail-closed boundary 유지
- SEMI OAuth page와 OpenRouter title 복원

## Required Gates

| Gate | Required evidence | Current status |
| --- | --- | --- |
| local verification | warnings-as-errors debug/release build·test, TSAN·ASAN, format, boundary, public consumer | PASS (2026-08-01, 90 tests per suite) |
| runtime/external | Codex registration, catalog, text, structured output, tool call, cancellation, revoke | PASS (2026-08-01, live account) |
| product flow | no-auth failure compensation, unsupported continuation fail-closed, account-to-terminal flow | PASS (2026-08-01, public SwiftPM consumer) |
| documentation contract | README, Docs index, contract, matrix, release record links | PASS (legacy naming exact-word scan clean) |

## Candidate Archive Verification

- 2026-08-01: exact candidate commit을 새 임시 directory에 `git archive`로 추출했다.
- 추출본에서 warnings-as-errors debug·release build/test와 source boundary 검사를 통과했다
  (각 test suite 90개).

## Publish Rules

- clean working tree의 exact commit만 `git archive`로 새 directory에 추출해 검증한다.
- tag, push, GitHub Release는 사용자의 명시적 게시 요청 없이는 실행하지 않는다.
- live provider credential과 response body는 문서·로그·release artifact에 기록하지 않는다.
