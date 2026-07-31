# Documentation

코드와 검증 결과를 기준으로 유지하는 SEMIProviderKit 문서다. 충돌 시
`Package.swift`와 `Sources/`, 실행된 테스트 결과가 우선한다.

| 문서 | 역할 |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 제품 정체성, 모듈·상태·효과·실패 경계 |
| [INTERFACE_CONTRACT.md](INTERFACE_CONTRACT.md) | 입력, 출력, 산출물과 호출자 책임 |
| [FUNCTIONAL_MATRIX.md](FUNCTIONAL_MATRIX.md) | 기능별 소유권·구현·검증 추적 |
| [COMPLETION_REPORT.md](COMPLETION_REPORT.md) | Git release 상태, 실제 검증, 제약과 잔여 위험 |
| [RELEASE_0.2.0.md](RELEASE_0.2.0.md) | 0.2.0 변경, 게시 gate, 중단·롤백 절차 |
| [RELEASE_NOTES_0.2.0.md](RELEASE_NOTES_0.2.0.md) | 0.2.0 사용자 영향과 breaking change |

새 사용자는 루트 [README](../README.md)에서 시작하고, 구현 변경 전에는
architecture와 interface contract를 함께 확인한다.
