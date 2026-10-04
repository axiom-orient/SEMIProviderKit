# Documentation

SEMIProviderKit의 현재 계약과 검증 근거다. 충돌하면 `Package.swift`, `Sources/`,
실행된 로컬 검증 결과가 우선한다.

| 문서 | 역할 |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | product 경계, 모듈·상태·효과·실패 모델 |
| [INTERFACE_CONTRACT.md](INTERFACE_CONTRACT.md) | 호출자 입력, 출력, credential·lifecycle 책임 |
| [FUNCTIONAL_MATRIX.md](FUNCTIONAL_MATRIX.md) | package 소유 기능과 검증 범위 |

시작점은 [Integration](INTERFACE_CONTRACT.md#integration)이다. 구현 변경 전에는 architecture와 interface
contract를 함께 확인한다.

## 검증과 공개

통합 검증의 유일한 진입점은 [`../Scripts/verify.sh`](../Scripts/verify.sh)다.
이 명령은 Swift build·test, sanitizer, format과 provider boundary 검사를
실행한다. `Package.swift`와 source contract가 일치하는 clean commit을 archive로
추출해 같은 gate를 다시 통과하기 전에는 release 또는 GitHub publication을
완료로 판정하지 않는다.
