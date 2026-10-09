import Foundation
import SEMIProviderCore

package actor ProviderAccountSupervisor {
  private let registry: BuiltInProviderRegistry
  private let store: any ProviderCredentialStore
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderClock
  /// Sessions stay registered until `run()` returns so every join point sees
  /// them. `accountIndex` is released earlier, at the terminal event, so the
  /// account ID can be re-registered as soon as the outcome is observable.
  private var sessions: [UUID: ProviderAccountRegistrationSession] = [:]
  private var accountIndex: [ProviderAccountID: UUID] = [:]
  /// Revoke boundary forwarded by ProviderRuntime and checked before session admission.
  private var accountAdmissionGenerations: [ProviderAccountID: UUID] = [:]
  private var inspections: [ProviderAccountID: ProviderAccountInspection] = [:]
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

  package func reconcileCredentials() async throws -> ProviderCredentialReconciliationReport {
    guard !shuttingDown else {
      throw ProviderFailure(code: .cancelled, message: "provider runtime is shutting down")
    }
    guard sessions.isEmpty else {
      throw ProviderFailure(
        code: .invalidRequest,
        message: "credential reconciliation requires no active account registration"
      )
    }

    let records = try await store.records()
    try ProviderCredentialContract.validate(records: records)
    var activeRecordCount = 0
    var removed: [ProviderCredentialReference] = []
    var issues: [ProviderCredentialReconciliationIssue] = []

    for record in records.sorted(by: Self.recordOrder) {
      switch record.state {
      case .active:
        activeRecordCount += 1
      case .staged:
        do {
          try await store.remove(record)
          removed.append(record.reference)
          inspections.removeValue(forKey: record.accountID)
        } catch {
          issues.append(
            ProviderCredentialReconciliationIssue(
              reference: record.reference,
              accountID: record.accountID,
              failure: ProviderFailure(
                code: .credentialRecoveryRequired,
                message: ProviderWireError.failure(error).message
              )
            )
          )
        }
      }
    }

    return try ProviderCredentialReconciliationReport(
      activeRecordCount: activeRecordCount,
      removedStagedReferences: removed,
      issues: issues
    )
  }

  package func accounts() async throws -> [ProviderAccountSummary] {
    let records = try await store.records()
    try ProviderCredentialContract.validate(records: records)
    return records.map { record in
      let readiness: ProviderAccountReadiness =
        record.state == .active
        ? (inspections[record.accountID]?.readiness ?? .verificationRequired)
        : .recoveryRequired
      return ProviderAccountSummary(
        accountID: record.accountID,
        providerID: record.providerID,
        label: record.label,
        credentialSource: record.source,
        readiness: readiness,
        endpoint: record.endpoint,
        lastInspectedAt: inspections[record.accountID]?.inspectedAt
      )
    }.sorted { left, right in
      if left.providerID != right.providerID {
        return left.providerID.rawValue < right.providerID.rawValue
      }
      return left.accountID.rawValue < right.accountID.rawValue
    }
  }

  package func register(
    _ request: ProviderAccountRegistrationRequest,
    admissionGeneration: UUID
  ) async -> ProviderAccountEventStream {
    let (stream, sink) = ProviderAccountEventStream.make()
    guard !shuttingDown else {
      Task {
        _ = await sink.send(
          .failed(ProviderFailure(code: .cancelled, message: "provider runtime is shutting down"))
        )
      }
      return stream
    }
    if let currentGeneration = accountAdmissionGenerations[request.accountID],
      currentGeneration != admissionGeneration
    {
      Task {
        _ = await sink.send(
          .failed(
            ProviderFailure(
              code: .accountUnavailable,
              message: "provider account registration was invalidated by account revocation"
            )
          )
        )
      }
      return stream
    }
    guard accountIndex[request.accountID] == nil else {
      Task {
        _ = await sink.send(
          .failed(
            ProviderFailure(
              code: .invalidRequest,
              message: "provider account registration is already active"
            )
          )
        )
      }
      return stream
    }

    let registrationID = UUID()
    let session = ProviderAccountRegistrationSession(
      registrationID: registrationID,
      request: request,
      registry: registry,
      store: store,
      transport: transport,
      clock: clock,
      sink: sink,
      didInspect: { [weak self] inspection in
        await self?.record(inspection: inspection)
      },
      releaseAccountID: { [weak self] accountID, registrationID in
        await self?.releaseAccountID(accountID: accountID, registrationID: registrationID)
      },
      didFinish: { [weak self] registrationID in
        await self?.removeSession(registrationID: registrationID)
      }
    )
    sessions[registrationID] = session
    accountIndex[request.accountID] = registrationID
    await session.start()
    return stream
  }

  package func cancel(accountID: ProviderAccountID) async {
    guard let registrationID = accountIndex[accountID],
      let session = sessions[registrationID]
    else { return }
    await session.cancel()
    await session.waitUntilFinished()
  }

  package func revoke(
    accountID: ProviderAccountID,
    admissionGeneration: UUID
  ) async throws {
    accountAdmissionGenerations[accountID] = admissionGeneration
    if let registrationID = accountIndex[accountID], let session = sessions[registrationID] {
      await session.cancel()
      await session.waitUntilFinished()
    }
    guard let record = try await store.record(accountID: accountID) else {
      inspections.removeValue(forKey: accountID)
      return
    }
    try await store.remove(record)
    inspections.removeValue(forKey: accountID)
  }

  package func inspect(accountID: ProviderAccountID) async throws -> ProviderAccountInspection {
    guard !shuttingDown else {
      throw ProviderFailure(code: .cancelled, message: "provider runtime is shutting down")
    }
    let lease = try ProviderCredentialContract.validate(
      lease: try await store.lease(accountID: accountID),
      expectedAccountID: accountID
    )
    let adapter = try registry.adapter(for: lease.record.providerID)
    let inspection = try await adapter.inspect(
      credential: lease,
      transport: transport,
      clock: clock
    )
    inspections[accountID] = inspection
    return inspection
  }

  package func models(accountID: ProviderAccountID) async throws -> ProviderModelCatalogResult {
    guard !shuttingDown else {
      throw ProviderFailure(code: .cancelled, message: "provider runtime is shutting down")
    }
    let lease = try ProviderCredentialContract.validate(
      lease: try await store.lease(accountID: accountID),
      expectedAccountID: accountID
    )
    let adapter = try registry.adapter(for: lease.record.providerID)
    return try await adapter.models(
      credential: lease,
      transport: transport,
      clock: clock
    )
  }

  package func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
    let active = Array(sessions.values)
    for session in active { await session.cancel() }
    for session in active { await session.waitUntilFinished() }
    sessions.removeAll(keepingCapacity: false)
    accountIndex.removeAll(keepingCapacity: false)
  }

  private func record(inspection: ProviderAccountInspection) {
    inspections[inspection.accountID] = inspection
  }

  /// Frees the account ID for re-registration while the session stays joinable.
  private func releaseAccountID(
    accountID: ProviderAccountID,
    registrationID: UUID
  ) {
    guard accountIndex[accountID] == registrationID else { return }
    accountIndex.removeValue(forKey: accountID)
  }

  private func removeSession(registrationID: UUID) {
    sessions.removeValue(forKey: registrationID)
  }

  private static func recordOrder(
    _ left: ProviderCredentialRecord,
    _ right: ProviderCredentialRecord
  ) -> Bool {
    if left.accountID != right.accountID {
      return left.accountID.rawValue < right.accountID.rawValue
    }
    return left.reference.rawValue < right.reference.rawValue
  }
}

package actor ProviderAccountRegistrationSession {
  private let registrationID: UUID
  private let request: ProviderAccountRegistrationRequest
  private let registry: BuiltInProviderRegistry
  private let store: any ProviderCredentialStore
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderClock
  private let sink: ProviderAccountEventSink
  private let didInspect: @Sendable (ProviderAccountInspection) async -> Void
  private let releaseAccountID: @Sendable (ProviderAccountID, UUID) async -> Void
  private let didFinish: @Sendable (UUID) async -> Void
  private var state = ProviderAccountState()
  private var task: Task<Void, Never>?
  private var cancellationRequested = false
  private var activationCommitStarted = false
  private var finished = false
  private var accountReleased = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  package init(
    registrationID: UUID,
    request: ProviderAccountRegistrationRequest,
    registry: BuiltInProviderRegistry,
    store: any ProviderCredentialStore,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock,
    sink: ProviderAccountEventSink,
    didInspect: @escaping @Sendable (ProviderAccountInspection) async -> Void,
    releaseAccountID: @escaping @Sendable (ProviderAccountID, UUID) async -> Void,
    didFinish: @escaping @Sendable (UUID) async -> Void
  ) {
    self.registrationID = registrationID
    self.request = request
    self.registry = registry
    self.store = store
    self.transport = transport
    self.clock = clock
    self.sink = sink
    self.didInspect = didInspect
    self.releaseAccountID = releaseAccountID
    self.didFinish = didFinish
  }

  package func start() {
    guard task == nil, !finished else { return }
    task = Task { await run() }
  }

  package func cancel() {
    guard !finished, !activationCommitStarted else { return }
    cancellationRequested = true
    task?.cancel()
  }

  package func waitUntilFinished() async {
    guard !finished else { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  private func run() async {
    do {
      try await apply(.registrationRequested(request))
    } catch {
      await fail(ProviderWireError.failure(error))
    }
    finished = true
    task = nil
    await releaseAccount()
    let waiters = finishWaiters
    finishWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
    await didFinish(registrationID)
  }

  private func apply(_ event: ProviderAccountEvent) async throws {
    let transition = try ProviderAccountReducer.reduce(state: state, event: event)
    state = transition.0

    if shouldInterruptForCancellation(after: event) {
      try await apply(.cancellationRequested)
      return
    }

    for effect in transition.1 {
      switch effect {
      case .publish(let event):
        if event.isTerminal { await releaseAccount() }
        guard await sink.send(event) else {
          throw ProviderFailure(
            code: .consumerBackpressureExceeded,
            message: "provider account event consumer exceeded its backlog"
          )
        }
      case .stageCredential(let request, let generation):
        guard generation == state.generation else { continue }
        try checkCancellation()
        do {
          let record = try await store.stage(request, at: await clock.now())
          try await apply(.credentialStaged(record))
        } catch {
          try await apply(.operationFailed(ProviderWireError.failure(error)))
        }
      case .verifyCredential(let request, let record, let generation):
        guard generation == state.generation else { continue }
        try checkCancellation()
        do {
          let adapter = try registry.adapter(for: request.providerID)
          let lease = try ProviderCredentialContract.validate(
            lease: ProviderCredentialLease(record: record, material: request.credential),
            expectedAccountID: request.accountID,
            expectedProviderID: request.providerID,
            requiresActiveRecord: false
          )
          let inspection = try await adapter.inspect(
            credential: lease,
            transport: transport,
            clock: clock
          )
          try await apply(.verificationSucceeded(inspection))
        } catch is CancellationError {
          try await apply(.cancellationRequested)
        } catch {
          try await apply(.operationFailed(ProviderWireError.failure(error)))
        }
      case .activateCredential(let record, let generation):
        guard generation == state.generation else { continue }
        try checkCancellation()
        do {
          try await store.activate(record, at: await clock.now())
          try checkCancellation()
          let activatedLease: ProviderCredentialLease
          do {
            activatedLease = try await store.lease(accountID: record.accountID)
          } catch {
            throw ProviderFailure(
              code: .credentialRecoveryRequired,
              message: "credential activation could not be read back"
            )
          }
          _ = try ProviderCredentialContract.validateActivated(
            lease: activatedLease,
            stagedRecord: record
          )
          try checkCancellation()
          guard case .activatingCredential(_, _, let inspection) = state.phase else {
            throw ProviderFailure(
              code: .internalInvariant,
              message: "provider registration lost its verified inspection"
            )
          }
          // This is the registration commit point. Cancellation that wins before
          // it compensates the credential; cancellation after it is ignored.
          activationCommitStarted = true
          await didInspect(inspection)
          try await apply(.activationSucceeded)
        } catch is CancellationError {
          try await apply(.cancellationRequested)
        } catch {
          try await apply(.operationFailed(ProviderWireError.failure(error)))
        }
      case .removeStagedCredential(let record, let generation):
        guard generation == state.generation else { continue }
        // Compensation is a recovery effect. It must run to completion even when
        // the registration task itself was cancelled.
        let cleanup = Task { [store] in
          try await store.remove(record)
        }
        do {
          try await cleanup.value
          try await apply(.compensationSucceeded)
        } catch {
          try await apply(.compensationFailed(ProviderWireError.failure(error)))
        }
      }
    }
  }

  private func shouldInterruptForCancellation(after event: ProviderAccountEvent) -> Bool {
    guard !activationCommitStarted, cancellationRequested || Task.isCancelled else {
      return false
    }
    switch event {
    case .registrationRequested, .credentialStaged, .verificationSucceeded:
      switch state.phase {
      case .stagingCredential, .verifyingAccount, .activatingCredential:
        return true
      default:
        return false
      }
    default:
      return false
    }
  }

  private func checkCancellation() throws {
    guard !cancellationRequested, !Task.isCancelled else {
      throw CancellationError()
    }
  }

  private func releaseAccount() async {
    guard !accountReleased else { return }
    accountReleased = true
    await releaseAccountID(request.accountID, registrationID)
  }

  private func fail(_ failure: ProviderFailure) async {
    do {
      if case .stagingCredential = state.phase {
        try await apply(.operationFailed(failure))
      } else if case .verifyingAccount = state.phase {
        try await apply(.operationFailed(failure))
      } else if case .activatingCredential = state.phase {
        try await apply(.operationFailed(failure))
      } else if case .compensating = state.phase {
        try await apply(.compensationFailed(failure))
      } else {
        _ = await sink.send(.failed(failure))
      }
    } catch {
      _ = await sink.send(.failed(ProviderWireError.failure(error)))
    }
  }
}
