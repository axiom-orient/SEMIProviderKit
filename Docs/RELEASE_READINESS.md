# Release Readiness

## Candidate Scope

- public subscription provider identity는 `codex`와 `codex_responses`
- OpenAI·Gemini continuation storage opt-in과 Codex fail-closed boundary 유지
- documented OpenRouter PKCE URL과 loopback callback state 검증
- Codex의 caller-owned history 반복 turn과 unqualified `maximumOutputTokens` fail-closed
  경계 추가
- failed tool result의 의미 보존과 displayable reasoning streaming 정규화

## Public Contract

subscription provider의 공개 ID와 protocol family는 각각 `codex`와 `codex_responses`다.

## Required Gates

| Gate | Required evidence | Current status |
| --- | --- | --- |
| local verification | warnings-as-errors debug/release build·test, TSAN·ASAN, format, boundary | PASS (2026-08-03, current clean archive / 3 suites / 104 tests) |
| public consumer | 세 public product import·build·실행 | PASS (2026-08-02, ephemeral SwiftPM consumer) |
| runtime/external | Codex registration, catalog, exact text streaming response, revoke | PASS (2026-08-02, live subscription / ephemeral public SwiftPM consumer) |
| product flow | missing-auth compensation, unqualified parameter·continuation fail-closed, account-to-terminal flow | PASS (2026-08-02, public SwiftPM consumer) |
| documentation contract | README, Docs index, contract, matrix, release record links | PASS |

## Candidate Archive Verification

- 2026-08-01: exact candidate commit을 새 임시 directory에 `git archive`로 추출했다.
- 추출본에서 warnings-as-errors debug·release build/test와 source boundary 검사를 통과했다
  (3개 suite, 총 91개 test).
- 2026-08-02: release candidate commit을 새 임시 directory에 `git archive`로 추출했다.
  추출본에서 warnings-as-errors debug·release build/test, TSAN, ASAN, format, source boundary
  검사를 통과했다 (3개 suite, 총 92개 test).
- 2026-08-03: release candidate commit을 새 임시 directory에 `git archive`로 추출했다.
  추출본에서 warnings-as-errors debug·release build/test, TSAN, ASAN, format, source boundary
  검사를 통과했다 (3개 suite, 총 98개 test).
- 2026-08-03: current candidate commit을 새 임시 directory에 `git archive`로 추출했다. 추출본에서
  warnings-as-errors debug·release build/test, TSAN, ASAN, format, source boundary 검사를
  통과했다 (3개 suite, 총 104개 test).

## Current Live Scenario Evidence

- 2026-08-02: 임시 외부 SwiftPM executable이 local package dependency로 public product를
  import했다. 기존 Codex auth reference를 내용 노출 없이 사용해 `register → models(8) →`
  exact `SEMI_LIVE_OK` streaming turn `→ revoke`를 완료했다.
- 같은 executable에서 존재하지 않는 auth reference로 등록을 시도했다. terminal failure 뒤
  `accounts()`가 비어 있음을 확인해 staged credential 보상 제거를 검증했다.
- 이 증거는 현재 worktree 기준이다. 배포 판정에는 아래 checklist의 clean commit archive
  재실행 결과만 사용한다.

## Publish Checklist

- [ ] 문서와 source를 포함한 clean working tree의 exact commit을 release candidate로 고정한다.
- [ ] 고정 commit을 새 directory에 `git archive`로 추출해 local verification gate를 다시 실행한다.
- [ ] archive checksum을 생성하고 release metadata에 archive 밖의 값으로 기록한다.
- [ ] 게시 승인 뒤에만 tag, push, GitHub Release를 생성한다.

## Stop and Rollback

- published artifact 또는 checksum이 고정 commit과 다르면 게시를 중단한다.
- 게시 뒤 계약 문제가 발견되면 tag를 재사용하거나 force-push하지 않는다. 이전 검증 tag를
  유지하고, 수정 release에 새 semantic version을 부여한다.

## Draft Release Notes
- **Behavior:** Codex continuation은 지원되지 않는 server-side retention 경로이므로 provider
  transport를 열기 전에 `capabilityMismatch`로 거부한다.
- **Behavior:** Codex 반복 대화는 caller-owned history를 재전송하며,
  `maximumOutputTokens`는 qualified parameter가 아니므로 network 전 거부한다.
- **Behavior:** OpenRouter PKCE URL은 documented `callback_url` 형식을 사용하며, loopback
  callback의 state·origin·query를 fail-closed 검증한다.
- **Validation:** clean archive에서 debug/release build, 104 tests, TSAN, ASAN, format,
  boundary 검사와 public SwiftPM consumer 검증을 완료한다.

## Publish Rules

- clean working tree의 exact commit만 `git archive`로 새 directory에 추출해 검증한다.
- tag, push, GitHub Release는 사용자의 명시적 게시 요청 없이는 실행하지 않는다.
- live provider credential과 response body는 문서·로그·release artifact에 기록하지 않는다.
