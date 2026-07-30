import Foundation

public struct ProviderExecutionState: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    case opening(ProviderTurnRequest)
    case streaming(
      ProviderTurnRequest,
      ProviderResponseMetadata,
      hasVisibleOutput: Bool
    )
    case terminating(
      ProviderTurnRequest,
      ProviderTerminal,
      cancelTransport: Bool
    )
    case terminal(ProviderTerminal)
  }

  public let generation: UInt64
  public let hasPublishedStarted: Bool
  public let phase: Phase

  public init(
    generation: UInt64 = 0,
    hasPublishedStarted: Bool = false,
    phase: Phase = .idle
  ) {
    self.generation = generation
    self.hasPublishedStarted = hasPublishedStarted
    self.phase = phase
  }
}

public enum ProviderExecutionEvent: Equatable, Sendable {
  case requestAdmitted(ProviderTurnRequest)
  case transportOpened(ProviderResponseMetadata)
  case retryRequested
  case textDeltaReceived(String)
  case toolCallCompleted(ProviderToolCall)
  case transportCompleted(ProviderCompletion)
  case transportFailed(ProviderFailure)
  case cancelRequested
  case timeoutExpired
  case mailboxOverflowed
  case cleanupCompleted
}

public enum ProviderExecutionEffect: Equatable, Sendable {
  case openTransport(ProviderTurnRequest, generation: UInt64)
  case publish(ProviderTurnEvent)
  case beginCleanup(cancelTransport: Bool, generation: UInt64)
}

public enum ProviderExecutionReducer {
  public static func reduce(
    state: ProviderExecutionState,
    event: ProviderExecutionEvent
  ) throws -> (ProviderExecutionState, [ProviderExecutionEffect]) {
    switch (state.phase, event) {
    case (.idle, .requestAdmitted(let request)):
      let generation = try nextGeneration(state.generation)
      return (
        .init(generation: generation, hasPublishedStarted: false, phase: .opening(request)),
        [.openTransport(request, generation: generation)]
      )

    case (.opening(let request), .transportOpened(let metadata)):
      guard metadata.requestID == request.id,
        metadata.providerID == request.selection.providerID,
        metadata.modelID == request.selection.modelID
      else {
        throw invalidTransition("transport metadata does not match the admitted request")
      }
      return (
        .init(
          generation: state.generation,
          hasPublishedStarted: true,
          phase: .streaming(request, metadata, hasVisibleOutput: false)
        ),
        state.hasPublishedStarted ? [] : [.publish(.started(metadata))]
      )

    case (
      .streaming(let request, let metadata, _),
      .textDeltaReceived(let delta)
    ):
      guard !delta.isEmpty,
        delta.unicodeScalars.count <= 1_048_576,
        !delta.unicodeScalars.contains(where: { $0.value == 0 })
      else {
        throw invalidTransition("provider text delta is empty or invalid")
      }
      return (
        .init(
          generation: state.generation,
          hasPublishedStarted: state.hasPublishedStarted,
          phase: .streaming(request, metadata, hasVisibleOutput: true)
        ),
        [.publish(.textDelta(delta))]
      )

    case (
      .streaming(let request, let metadata, _),
      .toolCallCompleted(let call)
    ):
      return (
        .init(
          generation: state.generation,
          hasPublishedStarted: state.hasPublishedStarted,
          phase: .streaming(request, metadata, hasVisibleOutput: true)
        ),
        [.publish(.toolCall(call))]
      )

    case (
      .streaming(let request, let metadata, _),
      .transportCompleted(let completion)
    ):
      let terminal = ProviderTerminal.completed(completion)
      return terminating(
        state: state,
        request: request,
        terminal: terminal,
        cancelTransport: false,
        effectsBeforeCleanup: state.hasPublishedStarted
          ? [] : [.publish(.started(metadata))]
      )

    case (.streaming(let request, _, false), .retryRequested):
      return (
        .init(
          generation: state.generation,
          hasPublishedStarted: state.hasPublishedStarted,
          phase: .opening(request)
        ),
        []
      )

    case (.opening(let request), .transportFailed(let failure)),
      (.streaming(let request, _, _), .transportFailed(let failure)):
      return terminating(
        state: state,
        request: request,
        terminal: .failed(failure),
        cancelTransport: true
      )

    case (.opening(let request), .cancelRequested),
      (.streaming(let request, _, _), .cancelRequested):
      return terminating(
        state: state,
        request: request,
        terminal: .cancelled,
        cancelTransport: true
      )

    case (.opening(let request), .timeoutExpired),
      (.streaming(let request, _, _), .timeoutExpired):
      return terminating(
        state: state,
        request: request,
        terminal: .failed(
          ProviderFailure(
            code: .timedOut,
            message: "provider request timed out",
            requestID: request.id
          )
        ),
        cancelTransport: true
      )

    case (.opening(let request), .mailboxOverflowed),
      (.streaming(let request, _, _), .mailboxOverflowed):
      return terminating(
        state: state,
        request: request,
        terminal: .failed(
          ProviderFailure(
            code: .consumerBackpressureExceeded,
            message: "provider event consumer exceeded the bounded backlog",
            requestID: request.id
          )
        ),
        cancelTransport: true
      )

    case (.terminating(_, let terminal, _), .cleanupCompleted):
      return (
        .init(
          generation: state.generation,
          hasPublishedStarted: state.hasPublishedStarted,
          phase: .terminal(terminal)
        ),
        [.publish(.terminal(terminal))]
      )

    case (.terminating, .cancelRequested), (.terminal, .cancelRequested):
      return (state, [])

    case (.terminal, _):
      return (state, [])

    default:
      throw invalidTransition("provider execution event is invalid for the current phase")
    }
  }

  private static func terminating(
    state: ProviderExecutionState,
    request: ProviderTurnRequest,
    terminal: ProviderTerminal,
    cancelTransport: Bool,
    effectsBeforeCleanup: [ProviderExecutionEffect] = []
  ) -> (ProviderExecutionState, [ProviderExecutionEffect]) {
    (
      .init(
        generation: state.generation,
        hasPublishedStarted: state.hasPublishedStarted,
        phase: .terminating(
          request,
          terminal,
          cancelTransport: cancelTransport
        )
      ),
      effectsBeforeCleanup
        + [.beginCleanup(cancelTransport: cancelTransport, generation: state.generation)]
    )
  }

  private static func nextGeneration(_ value: UInt64) throws -> UInt64 {
    let (next, overflowed) = value.addingReportingOverflow(1)
    guard !overflowed else {
      throw ProviderCoreError(
        code: .generationExhausted,
        message: "provider execution generation exhausted"
      )
    }
    return next
  }

  private static func invalidTransition(_ message: String) -> ProviderCoreError {
    .init(code: .invalidTransition, message: message)
  }
}
