# Documentation

SEMIProviderKit의 현재 계약과 검증 근거다. 충돌하면 `Package.swift`, `Sources/`,
실행된 로컬 검증 결과가 우선한다.

| 문서 | 역할 |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | product 경계, 모듈·상태·효과·실패 모델 |
| [INTERFACE_CONTRACT.md](INTERFACE_CONTRACT.md) | 호출자 입력, 출력, credential·lifecycle 책임 |
| [FUNCTIONAL_MATRIX.md](FUNCTIONAL_MATRIX.md) | package 소유 기능과 검증 상태 |
| [COMPLETION_REPORT.md](COMPLETION_REPORT.md) | 현재 source의 실행 증거와 외부 검증 범위 |
| [RELEASE_READINESS.md](RELEASE_READINESS.md) | 0.3.0의 계약 변경, local·live·archive·rollback gate |

시작점은 루트 [README](../README.md)다. 구현 변경 전에는 architecture와 interface
contract를 함께 확인한다.
