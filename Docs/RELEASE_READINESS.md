# 0.3.0 Release Readiness

## Candidate Scope

- public subscription provider identity를 `codex`와 `codex_responses`로 정리
- ARA와 이전 release 문서·parity 문서 제거
- OpenAI·Gemini continuation storage opt-in과 Codex fail-closed boundary 유지
- SEMI OAuth page와 OpenRouter title 복원

## Public Contract and Migration

0.3.0 candidate는 `BuiltInProviderID.soa`를 `.codex`로, `ProviderProtocolFamily.soaResponses`
를 `.codexResponses`로 바꾼 breaking public API change다. compatibility wrapper는 없다.
호출자는 source를 갱신하고 durable provider selection의 `"soa"`를 `"codex"`로
migration해야 한다. 이 계약 변경은 `0.3.0` release에서 명시한다.

## Required Gates

| Gate | Required evidence | Current status |
| --- | --- | --- |
| local verification | warnings-as-errors debug/release build·test, TSAN·ASAN, format, boundary, public consumer | PASS (2026-08-01, 3 suites / 91 tests) |
| runtime/external | Codex registration, catalog, text, structured output, tool call, cancellation, revoke | PASS (2026-08-01, live account) |
| product flow | no-auth failure compensation, unsupported continuation fail-closed, account-to-terminal flow | PASS (2026-08-01, public SwiftPM consumer) |
| documentation contract | README, Docs index, contract, matrix, release record links | PASS (migration and test-count records updated) |

## Candidate Archive Verification

- 2026-08-01: exact candidate commit을 새 임시 directory에 `git archive`로 추출했다.
- 추출본에서 warnings-as-errors debug·release build/test와 source boundary 검사를 통과했다
  (3개 suite, 총 91개 test).

## Publish Checklist

- [x] breaking change의 semantic version을 `0.3.0`으로 결정했다.
- [ ] 문서와 source를 포함한 clean working tree의 exact commit을 release candidate로 고정한다.
- [ ] 고정 commit을 새 directory에 `git archive`로 추출해 local verification gate를 다시 실행한다.
- [ ] archive checksum을 생성하고 release metadata에 archive 밖의 값으로 기록한다.
- [ ] 게시 승인 뒤에만 tag, push, GitHub Release를 생성한다.

## Stop and Rollback

- migration하지 않은 호출자가 `soa` identifier를 보내거나 compile error가 나면 게시를 중단한다.
- published artifact 또는 checksum이 고정 commit과 다르면 게시를 중단한다.
- 게시 뒤 계약 문제가 발견되면 tag를 재사용하거나 force-push하지 않는다. 이전 검증 tag를
  유지하고, 수정 release에 새 semantic version과 migration note를 부여한다.

## 0.3.0 Draft Release Notes

- **Breaking:** subscription provider ID는 `soa`에서 `codex`로, protocol family는
  `soa_responses`에서 `codex_responses`로 바뀐다. compatibility wrapper는 제공하지 않는다.
- **Behavior:** Codex continuation은 지원되지 않는 server-side retention 경로이므로 provider
  transport를 열기 전에 `capabilityMismatch`로 거부한다.
- **Validation:** clean archive에서 debug/release build, 91 tests, TSAN, ASAN, format,
  boundary 검사와 public SwiftPM consumer 검증을 완료한다.

## Publish Rules

- clean working tree의 exact commit만 `git archive`로 새 directory에 추출해 검증한다.
- tag, push, GitHub Release는 사용자의 명시적 게시 요청 없이는 실행하지 않는다.
- live provider credential과 response body는 문서·로그·release artifact에 기록하지 않는다.
