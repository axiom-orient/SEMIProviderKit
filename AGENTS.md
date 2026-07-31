# Repository Instructions

## Build and release policy

- GitHub Actions와 GitHub CI를 사용하지 않는다.
- `.github/workflows/` 아래에 workflow를 생성·복원·활성화하지 않는다.
- build, format, architecture boundary, test, sanitizer, public API, clean extraction
  검증은 지원 대상 macOS의 로컬 환경에서 실행한다.
- 릴리스 판정은 clean working tree의 exact Git commit을 `git archive`로 새
  디렉터리에 추출해 로컬 검증한 결과를 기준으로 한다.
- 원격 CI 상태를 build·test·tag·release gate나 완료 근거로 사용하지 않는다.
- push, tag 생성, GitHub Release 게시에는 사용자의 명시적인 게시 요청이 필요하다.
