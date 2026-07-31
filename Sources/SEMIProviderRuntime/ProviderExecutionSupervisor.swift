import Foundation
import SEMIProviderCore

package actor ProviderExecutionSupervisor {
  private let registry: BuiltInProviderRegistry
  private let store: any ProviderCredentialStore
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderClock
  private struct ActiveExecution: Sendable {
    let accountID: ProviderAccountID
    let session: ProviderExecutionSession
  }

  /// Sessions live here from admission until `run()` returns, so every join
  /// point has a single source of truth. `requestIndex` is the separate,
  /// earlier-released view that lets a request ID be reused as soon as its
  /// terminal is observable.
  private var sessions: [UUID: ActiveExecution] = [:]
  private var requestIndex: [ProviderRequestID: UUID] = [:]
  private var accountIndex: [ProviderAccountID: Set<UUID>] = [:]
  private var shuttingDown = false

  package init(
    registry: BuiltInProviderRegistry,
    store: any ProviderCredentialStore,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) {
    self.registry = registry
    self.store = store
    self.transport = transport
    self.clock = clock
  }

  package func execute(_ request: ProviderTurnRequest) async -> ProviderEventStream {
    let (stream, sink) = ProviderEventStream.make()
    guard !shuttingDown else {
      Task {
        await sink.finish(
          with: .failed(
            ProviderFailure(
              code: .cancelled,
              message: "provider runtime is shutting down",
              requestID: request.id
            )
          )
        )
      }
      return stream
    }
    guard requestIndex[request.id] == nil else {
      Task {
        await sink.finish(
          with: .failed(
            ProviderFailure(
              code: .invalidRequest,
              message: "provider request ID is already active",
              requestID: request.id
            )
          )
        )
      }
      return stream
    }

    let executionID = UUID()
    let session = ProviderExecutionSession(
      executionID: executionID,
      request: request,
      registry: registry,
      store: store,
      transport: transport,
      clock: clock,
      sink: sink,
      releaseRequestID: { [weak self] requestID, executionID in
        await self?.releaseRequestID(requestID: requestID, executionID: executionID)
      },
      didFinish: { [weak self] executionID in
        await self?.removeSession(executionID: executionID)
      }
    )
    sessions[executionID] = ActiveExecution(
      accountID: request.selection.accountID,
      session: session
    )
    requestIndex[request.id] = executionID
    accountIndex[request.selection.accountID, default: []].insert(executionID)
    await session.start()
    return stream
  }

  package func cancel(_ requestID: ProviderRequestID) async {
    guard let executionID = requestIndex[requestID],
      let session = sessions[executionID]?.session
    else { return }
    await session.cancel()
    await session.waitUntilFinished()
  }

  package func cancelAndJoin(accountID: ProviderAccountID) async {
    let matching = (accountIndex[accountID] ?? []).compactMap { sessions[$0]?.session }
    for session in matching { await session.cancel() }
    for session in matching { await session.waitUntilFinished() }
  }

  package func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
    let active = sessions.values.map(\.session)
    for session in active { await session.cancel() }
    for session in active { await session.waitUntilFinished() }
    sessions.removeAll(keepingCapacity: false)
    requestIndex.removeAll(keepingCapacity: false)
    accountIndex.removeAll(keepingCapacity: false)
  }

  /// Frees the request ID for reuse while the session itself stays joinable.
  private func releaseRequestID(
    requestID: ProviderRequestID,
    executionID: UUID
  ) {
    guard requestIndex[requestID] == executionID else { return }
    requestIndex.removeValue(forKey: requestID)
  }

  private func removeSession(executionID: UUID) {
    guard let active = sessions.removeValue(forKey: executionID) else { return }
    accountIndex[active.accountID]?.remove(executionID)
    if accountIndex[active.accountID]?.isEmpty == true {
      accountIndex.removeValue(forKey: active.accountID)
    }
  }
}

package actor ProviderExecutionSession {
  private let executionID: UUID
  private let request: ProviderTurnRequest
  private let registry: BuiltInProviderRegistry
  private let store: any ProviderCredentialStore
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderClock
  private let sink: ProviderEventSink
  private let releaseRequestID: @Sendable (ProviderRequestID, UUID) async -> Void
  private let didFinish: @Sendable (UUID) async -> Void
  private var state = ProviderExecutionState()
  private var task: Task<Void, Never>?
  private var cancelTransport: (@Sendable () -> Void)?
  private var waitForTransportTermination: (@Sendable () async -> Void)?
  private var deadlineTask: Task<Void, Never>?
  private var requestedTermination: ProviderExecutionEvent?
  private var finished = false
  private var supervisorReleased = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  package init(
    executionID: UUID,
    request: ProviderTurnRequest,
    registry: BuiltInProviderRegistry,
    store: any ProviderCredentialStore,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock,
    sink: ProviderEventSink,
    releaseRequestID: @escaping @Sendable (ProviderRequestID, UUID) async -> Void,
    didFinish: @escaping @Sendable (UUID) async -> Void
  ) {
    self.executionID = executionID
    self.request = request
    self.registry = registry
    self.store = store
    self.transport = transport
    self.clock = clock
    self.sink = sink
    self.releaseRequestID = releaseRequestID
    self.didFinish = didFinish
  }

  package func start() {
    guard task == nil, !finished else { return }
    task = Task { await run() }
  }

  package func cancel() {
    requestTermination(.cancelRequested)
  }

  package func waitUntilFinished() async {
    guard !finished else { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  private func run() async {
    let terminalEvent: ProviderExecutionEvent
    do {
      let transition = try ProviderExecutionReducer.reduce(
        state: state,
        event: .requestAdmitted(request)
      )
      state = transition.0
      if let requestedTermination {
        terminalEvent = requestedTermination
      } else {
        deadlineTask = Task { [clock, timeout = request.constraints.timeoutMilliseconds] in
          do {
            try await clock.sleep(milliseconds: timeout)
            await self.timeoutExpired()
          } catch {
            // Cancellation is the normal completion path for the deadline watcher.
          }
        }
        terminalEvent = .transportCompleted(try await executeOpenEffect(transition.1))
      }
    } catch is CancellationError {
      terminalEvent = requestedTermination ?? .cancelRequested
    } catch {
      if Task.isCancelled {
        terminalEvent = requestedTermination ?? .cancelRequested
      } else {
        let failure = ProviderWireError.failure(error, requestID: request.id)
        terminalEvent =
          failure.code == .consumerBackpressureExceeded
          ? .mailboxOverflowed
          : .transportFailed(failure)
      }
    }

    let watcher = deadlineTask
    watcher?.cancel()
    deadlineTask = nil
    await watcher?.value
    await closeCurrentTransport(cancel: true)
    await terminate(terminalEvent)
    finished = true
    task = nil
    let waiters = finishWaiters
    finishWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
    await didFinish(executionID)
  }

  private func timeoutExpired() async {
    requestTermination(.timeoutExpired)
  }

  private func requestTermination(_ event: ProviderExecutionEvent) {
    guard !finished, requestedTermination == nil else { return }
    requestedTermination = event
    deadlineTask?.cancel()
    task?.cancel()
    cancelTransport?()
  }

  private func attach(_ response: ProviderHTTPResponse) throws {
    guard cancelTransport == nil, waitForTransportTermination == nil else {
      throw ProviderFailure(
        code: .internalInvariant,
        message: "provider execution attempted to attach a second active transport",
        requestID: request.id
      )
    }
    cancelTransport = response.cancel
    waitForTransportTermination = response.waitForTermination
  }

  private func closeCurrentTransport(cancel shouldCancel: Bool) async {
    let cancel = cancelTransport
    let wait = waitForTransportTermination
    cancelTransport = nil
    waitForTransportTermination = nil
    if shouldCancel { cancel?() }
    if let wait { await wait() }
  }

  private func executeOpenEffect(
    _ effects: [ProviderExecutionEffect]
  ) async throws -> ProviderCompletion {
    for effect in effects {
      guard case .openTransport(let admitted, let generation) = effect,
        admitted.id == request.id,
        generation == state.generation
      else { continue }
      return try await openAndConsume()
    }
    throw ProviderFailure(
      code: .internalInvariant,
      message: "provider execution admission emitted no transport effect",
      requestID: request.id
    )
  }

  private func openAndConsume() async throws -> ProviderCompletion {
    let lease = try ProviderCredentialContract.validate(
      lease: try await store.lease(accountID: request.selection.accountID),
      expectedAccountID: request.selection.accountID,
      expectedProviderID: request.selection.providerID
    )
    let adapter = try registry.adapter(for: request.selection.providerID)
    let wireRequest = try await adapter.makeExecutionRequest(request, credential: lease)

    var attempt = 1
    while true {
      try Task.checkCancellation()

      let response: ProviderHTTPResponse
      do {
        response = try await transport.open(wireRequest)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        let failure = ProviderWireError.failure(error, requestID: request.id)
        guard try await retryBeforeVisibleOutput(failure, attempt: attempt) else {
          throw failure
        }
        attempt += 1
        continue
      }

      try attach(response)
      if !(200..<300).contains(response.statusCode) {
        let body: Data
        do {
          body = try await collectBody(response.body, limit: wireRequest.maximumResponseBytes)
        } catch is CancellationError {
          await closeCurrentTransport(cancel: true)
          throw CancellationError()
        } catch {
          await closeCurrentTransport(cancel: true)
          if Task.isCancelled { throw CancellationError() }
          let failure = ProviderWireError.failure(error, requestID: request.id)
          guard try await retryBeforeVisibleOutput(failure, attempt: attempt) else {
            throw failure
          }
          attempt += 1
          continue
        }
        await closeCurrentTransport(cancel: false)
        let failure = ProviderWireError.httpFailure(
          statusCode: response.statusCode,
          headers: response.headers,
          body: body,
          requestID: request.id,
          now: await clock.now()
        )
        guard try await retryBeforeVisibleOutput(failure, attempt: attempt) else {
          throw failure
        }
        attempt += 1
        continue
      }

      do {
        let completion = try await consumeSuccessfulResponse(
          response,
          adapter: adapter
        )
        await closeCurrentTransport(cancel: false)
        try Task.checkCancellation()
        return completion
      } catch is CancellationError {
        await closeCurrentTransport(cancel: true)
        throw CancellationError()
      } catch {
        await closeCurrentTransport(cancel: true)
        if Task.isCancelled { throw CancellationError() }
        let failure = ProviderWireError.failure(error, requestID: request.id)
        guard try await retryBeforeVisibleOutput(failure, attempt: attempt) else {
          throw failure
        }
        attempt += 1
      }
    }
  }

  private func consumeSuccessfulResponse(
    _ response: ProviderHTTPResponse,
    adapter: any ProviderAdapter
  ) async throws -> ProviderCompletion {
    let decoder = try adapter.makeDecoder(for: request)
    let providerRequestID =
      response.headers["x-request-id"]
      ?? response.headers["request-id"]
      ?? response.headers["x-goog-request-id"]
    let metadata = try ProviderResponseMetadata(
      requestID: request.id,
      providerRequestID: providerRequestID,
      providerID: request.selection.providerID,
      modelID: request.selection.modelID,
      startedAt: await clock.now()
    )
    try await transitionAndPublish(.transportOpened(metadata))

    var sse = ServerSentEventDecoder()
    var completion: ProviderCompletion?
    for try await chunk in response.body {
      try Task.checkCancellation()
      for event in try sse.feed(chunk) {
        completion = try await consume(
          decoder: decoder,
          event: event,
          existingCompletion: completion
        )
      }
    }
    try Task.checkCancellation()
    for event in try sse.finish() {
      completion = try await consume(
        decoder: decoder,
        event: event,
        existingCompletion: completion
      )
    }
    for decoded in try decoder.finish() {
      completion = try await consume(
        decoded: decoded,
        existingCompletion: completion
      )
    }

    guard let completion else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider stream ended without a completion event",
        requestID: request.id
      )
    }
    return completion
  }

  private func retryBeforeVisibleOutput(
    _ failure: ProviderFailure,
    attempt: Int
  ) async throws -> Bool {
    guard attempt < request.constraints.maximumRetryAttempts,
      isRetryableBeforeVisibleOutput(failure),
      isBeforeVisibleOutput
    else { return false }

    if case .streaming = state.phase {
      let transition = try ProviderExecutionReducer.reduce(state: state, event: .retryRequested)
      state = transition.0
      precondition(transition.1.isEmpty)
    }
    let exponential = UInt64(250) << UInt64(max(0, attempt - 1))
    let requestedDelay = failure.retryAfterMilliseconds ?? exponential
    let delay = min(requestedDelay, 60_000)
    try await clock.sleep(milliseconds: delay)
    return true
  }

  private var isBeforeVisibleOutput: Bool {
    switch state.phase {
    case .opening:
      return true
    case .streaming(_, _, let hasVisibleOutput):
      return !hasVisibleOutput
    case .idle, .terminating, .terminal:
      return false
    }
  }

  private func isRetryableBeforeVisibleOutput(_ failure: ProviderFailure) -> Bool {
    switch failure.code {
    case .rateLimited, .serverFailed, .transportFailed, .timedOut:
      return true
    case .invalidRequest, .providerUnsupported, .accountUnavailable,
      .authenticationFailed, .permissionDenied, .modelUnavailable,
      .capabilityMismatch, .billingUnavailable, .responseTooLarge,
      .malformedResponse, .consumerBackpressureExceeded, .cancelled,
      .credentialRecoveryRequired, .internalInvariant:
      return false
    }
  }

  private func consume(
    decoder: any ProviderStreamDecoder,
    event: ServerSentEvent,
    existingCompletion: ProviderCompletion?
  ) async throws -> ProviderCompletion? {
    var completion = existingCompletion
    for decoded in try decoder.consume(event) {
      completion = try await consume(decoded: decoded, existingCompletion: completion)
    }
    return completion
  }

  private func consume(
    decoded: ProviderDecodedEvent,
    existingCompletion: ProviderCompletion?
  ) async throws -> ProviderCompletion? {
    if existingCompletion != nil {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider emitted data after its completion event",
        requestID: request.id
      )
    }
    switch decoded {
    case .textDelta(let value):
      try await transitionAndPublish(.textDeltaReceived(value))
      return nil
    case .toolCall(let call):
      try await transitionAndPublish(.toolCallCompleted(call))
      return nil
    case .completed(let draft):
      return try draft.materialize(at: await clock.now())
    }
  }

  private func transitionAndPublish(_ event: ProviderExecutionEvent) async throws {
    let transition = try ProviderExecutionReducer.reduce(state: state, event: event)
    state = transition.0
    for effect in transition.1 {
      guard case .publish(let publicEvent) = effect else { continue }
      try await publish(publicEvent)
    }
  }

  private func publish(_ event: ProviderTurnEvent) async throws {
    switch await sink.send(event) {
    case .accepted, .coalesced:
      break
    case .overflow:
      throw ProviderFailure(
        code: .consumerBackpressureExceeded,
        message: "provider event consumer exceeded the bounded backlog",
        requestID: request.id
      )
    case .closed:
      throw ProviderFailure(
        code: .internalInvariant,
        message: "provider event stream closed before execution cleanup",
        requestID: request.id
      )
    }
  }

  private func terminate(_ event: ProviderExecutionEvent) async {
    switch state.phase {
    case .terminating, .terminal:
      return
    case .idle:
      await releaseSupervisor()
      _ = await sink.finish(
        with: .failed(
          ProviderFailure(
            code: .internalInvariant,
            message: "provider execution terminated before admission",
            requestID: request.id
          )
        )
      )
      return
    case .opening, .streaming:
      break
    }

    do {
      let transition = try ProviderExecutionReducer.reduce(state: state, event: event)
      state = transition.0
      for effect in transition.1 {
        switch effect {
        case .publish(let publicEvent):
          try await publish(publicEvent)
        case .beginCleanup(let shouldCancel, let generation):
          guard generation == state.generation else { continue }
          await closeCurrentTransport(cancel: shouldCancel)
          let terminalTransition = try ProviderExecutionReducer.reduce(
            state: state,
            event: .cleanupCompleted
          )
          state = terminalTransition.0
          for terminalEffect in terminalTransition.1 {
            guard case .publish(.terminal(let terminal)) = terminalEffect else { continue }
            await releaseSupervisor()
            _ = await sink.finish(with: terminal)
          }
        case .openTransport:
          throw ProviderFailure(
            code: .internalInvariant,
            message: "provider cleanup attempted to reopen transport",
            requestID: request.id
          )
        }
      }
    } catch {
      await closeCurrentTransport(cancel: true)
      await releaseSupervisor()
      _ = await sink.finish(
        with: .failed(
          ProviderWireError.failure(error, requestID: request.id)
        )
      )
    }
  }

  private func releaseSupervisor() async {
    guard !supervisorReleased else { return }
    supervisorReleased = true
    await releaseRequestID(request.id, executionID)
  }

  private func collectBody(
    _ body: ProviderHTTPBodyStream,
    limit: Int
  ) async throws -> Data {
    var result = Data()
    for try await chunk in body {
      let (next, overflowed) = result.count.addingReportingOverflow(chunk.count)
      guard !overflowed, next <= limit else {
        throw ProviderTransportError.responseTooLarge
      }
      result.append(chunk)
    }
    return result
  }
}
