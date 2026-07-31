import Foundation

public struct ProviderAccountState: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    case stagingCredential(ProviderAccountRegistrationRequest)
    case verifyingAccount(
      ProviderAccountRegistrationRequest,
      ProviderCredentialRecord
    )
    case activatingCredential(
      ProviderAccountRegistrationRequest,
      ProviderCredentialRecord,
      ProviderAccountInspection
    )
    case ready(ProviderAccountSummary)
    case compensating(
      ProviderAccountRegistrationRequest,
      ProviderCredentialRecord,
      ProviderFailure
    )
    case failed(ProviderFailure)
    case recoveryRequired(ProviderCredentialRecord, ProviderFailure)
  }

  public let generation: UInt64
  public let phase: Phase

  public init(generation: UInt64 = 0, phase: Phase = .idle) {
    self.generation = generation
    self.phase = phase
  }
}

public enum ProviderAccountEvent: Sendable {
  case registrationRequested(ProviderAccountRegistrationRequest)
  case credentialStaged(ProviderCredentialRecord)
  case verificationSucceeded(ProviderAccountInspection)
  case activationSucceeded
  case cancellationRequested
  case operationFailed(ProviderFailure)
  case compensationSucceeded
  case compensationFailed(ProviderFailure)
}

public enum ProviderAccountPublicEvent: Equatable, Sendable {
  case staging
  case verifying
  case activating
  case ready(ProviderAccountSummary)
  case failed(ProviderFailure)
  case recoveryRequired(ProviderFailure)
}

extension ProviderAccountPublicEvent {
  package var isTerminal: Bool {
    switch self {
    case .ready, .failed, .recoveryRequired: true
    case .staging, .verifying, .activating: false
    }
  }
}

public enum ProviderAccountEffect: Sendable {
  case stageCredential(ProviderAccountRegistrationRequest, generation: UInt64)
  case verifyCredential(
    ProviderAccountRegistrationRequest,
    ProviderCredentialRecord,
    generation: UInt64
  )
  case activateCredential(ProviderCredentialRecord, generation: UInt64)
  case removeStagedCredential(ProviderCredentialRecord, generation: UInt64)
  case publish(ProviderAccountPublicEvent)
}

public enum ProviderAccountReducer {
  public static func reduce(
    state: ProviderAccountState,
    event: ProviderAccountEvent
  ) throws -> (ProviderAccountState, [ProviderAccountEffect]) {
    switch (state.phase, event) {
    case (.idle, .registrationRequested(let request)),
      (.failed, .registrationRequested(let request)):
      let generation = try nextGeneration(state.generation)
      return (
        .init(generation: generation, phase: .stagingCredential(request)),
        [.publish(.staging), .stageCredential(request, generation: generation)]
      )

    case (.stagingCredential(let request), .credentialStaged(let record)):
      do {
        try ProviderValueValidation.credentialRecord(record)
        guard record.accountID == request.accountID,
          record.providerID == request.providerID,
          record.label == request.label,
          record.source == request.credential.source,
          record.state == .staged,
          record.endpoint == request.endpoint
        else {
          throw invalidTransition("staged credential does not match registration")
        }
      } catch {
        let failure = ProviderFailure(
          code: .internalInvariant,
          message: "credential store returned an inconsistent staged record"
        )
        return (
          .init(
            generation: state.generation,
            phase: .compensating(request, record, failure)
          ),
          [.removeStagedCredential(record, generation: state.generation)]
        )
      }
      return (
        .init(
          generation: state.generation,
          phase: .verifyingAccount(request, record)
        ),
        [
          .publish(.verifying),
          .verifyCredential(request, record, generation: state.generation),
        ]
      )

    case (
      .verifyingAccount(let request, let record),
      .verificationSucceeded(let inspection)
    ):
      guard inspection.accountID == request.accountID,
        inspection.providerID == request.providerID,
        inspection.readiness == .ready
      else { throw invalidTransition("account verification did not produce a ready inspection") }
      return (
        .init(
          generation: state.generation,
          phase: .activatingCredential(request, record, inspection)
        ),
        [
          .publish(.activating),
          .activateCredential(record, generation: state.generation),
        ]
      )

    case (
      .activatingCredential(let request, let record, let inspection),
      .activationSucceeded
    ):
      let summary = ProviderAccountSummary(
        accountID: request.accountID,
        providerID: request.providerID,
        label: request.label,
        credentialSource: record.source,
        readiness: .ready,
        endpoint: request.endpoint,
        lastInspectedAt: inspection.inspectedAt
      )
      return (
        .init(generation: state.generation, phase: .ready(summary)),
        [.publish(.ready(summary))]
      )

    case (.stagingCredential, .operationFailed(let failure)):
      return (
        .init(generation: state.generation, phase: .failed(failure)),
        [.publish(.failed(failure))]
      )

    case (
      .verifyingAccount(let request, let record),
      .operationFailed(let failure)
    ),
      (
        .activatingCredential(let request, let record, _),
        .operationFailed(let failure)
      ):
      return (
        .init(
          generation: state.generation,
          phase: .compensating(request, record, failure)
        ),
        [.removeStagedCredential(record, generation: state.generation)]
      )

    case (
      .verifyingAccount(let request, let record),
      .cancellationRequested
    ),
      (
        .activatingCredential(let request, let record, _),
        .cancellationRequested
      ):
      let failure = ProviderFailure(
        code: .cancelled,
        message: "account registration cancelled"
      )
      return (
        .init(
          generation: state.generation,
          phase: .compensating(request, record, failure)
        ),
        [.removeStagedCredential(record, generation: state.generation)]
      )

    case (.stagingCredential, .cancellationRequested):
      let failure = ProviderFailure(code: .cancelled, message: "account registration cancelled")
      return (
        .init(generation: state.generation, phase: .failed(failure)),
        [.publish(.failed(failure))]
      )

    case (.compensating(_, _, let originalFailure), .compensationSucceeded):
      return (
        .init(generation: state.generation, phase: .failed(originalFailure)),
        [.publish(.failed(originalFailure))]
      )

    case (.compensating(_, let record, _), .compensationFailed(let failure)):
      return (
        .init(
          generation: state.generation,
          phase: .recoveryRequired(record, failure)
        ),
        [.publish(.recoveryRequired(failure))]
      )

    case (.ready, .cancellationRequested), (.failed, .cancellationRequested):
      return (state, [])

    default:
      throw invalidTransition("provider account event is invalid for the current phase")
    }
  }

  private static func nextGeneration(_ value: UInt64) throws -> UInt64 {
    let (next, overflowed) = value.addingReportingOverflow(1)
    guard !overflowed else {
      throw ProviderCoreError(
        code: .generationExhausted,
        message: "provider account generation exhausted"
      )
    }
    return next
  }

  private static func invalidTransition(_ message: String) -> ProviderCoreError {
    .init(code: .invalidTransition, message: message)
  }
}
