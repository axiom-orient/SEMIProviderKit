import Foundation
import SEMIProviderCore

/// The only public runtime facade. Provider codecs, transports, and supervisors remain package-private.
public actor ProviderRuntime {
  private enum Lifecycle {
    case running
    case shuttingDown
    case shutDown
  }

  private let accountSupervisor: ProviderAccountSupervisor
  private let executionSupervisor: ProviderExecutionSupervisor
  private let openRouterOAuthBroker: OpenRouterOAuthBroker
  private var consumedOAuthStates = OAuthStateReplayWindow(capacity: 4_096)
  private let initialAdmissionGeneration = UUID()
  /// Revocation advances the token; the account supervisor mirrors it for its actor-hop check.
  private var accountAdmissionGenerations: [ProviderAccountID: UUID] = [:]
  private var revokingAccounts: Set<ProviderAccountID> = []
  private var lifecycle: Lifecycle = .running
  private var activeControlOperations = 0
  private var controlDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    credentialStore: any ProviderCredentialStore,
    clock: any ProviderClock = SystemProviderClock()
  ) {
    let registry = BuiltInProviderRegistry()
    let transport = URLSessionProviderHTTPTransport()
    self.accountSupervisor = ProviderAccountSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.executionSupervisor = ProviderExecutionSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.openRouterOAuthBroker = OpenRouterOAuthBroker(transport: transport, clock: clock)
  }

  /// Creates a runtime with a host-supplied unary HTTP boundary. This is
  /// intended for host integration tests and adapters that already own their
  /// network transport; production callers should use the default initializer.
  public init(
    credentialStore: any ProviderCredentialStore,
    requestHandler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    clock: any ProviderClock = SystemProviderClock()
  ) {
    let registry = BuiltInProviderRegistry()
    let transport = ClosureProviderHTTPTransport(handler: requestHandler)
    self.accountSupervisor = ProviderAccountSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.executionSupervisor = ProviderExecutionSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.openRouterOAuthBroker = OpenRouterOAuthBroker(transport: transport, clock: clock)
  }

  package init(
    credentialStore: any ProviderCredentialStore,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) {
    let registry = BuiltInProviderRegistry()
    self.accountSupervisor = ProviderAccountSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.executionSupervisor = ProviderExecutionSupervisor(
      registry: registry,
      store: credentialStore,
      transport: transport,
      clock: clock
    )
    self.openRouterOAuthBroker = OpenRouterOAuthBroker(transport: transport, clock: clock)
  }

  public nonisolated func providers() -> [ProviderDescriptor] {
    BuiltInProviderRegistry().descriptors()
  }

  public func accounts() async throws -> [ProviderAccountSummary] {
    try beginControlOperation()
    defer { endControlOperation() }
    return try await accountSupervisor.accounts()
  }

  /// Reconciles credentials left in the staged state by an interrupted registration.
  /// Active credentials are never altered. Every cleanup failure remains visible in the report.
  public func reconcileCredentials() async throws -> ProviderCredentialReconciliationReport {
    try beginControlOperation()
    defer { endControlOperation() }
    return try await accountSupervisor.reconcileCredentials()
  }

  public func register(
    _ request: ProviderAccountRegistrationRequest
  ) async -> ProviderAccountEventStream {
    guard lifecycle == .running else {
      return ProviderAccountEventStream.failed(shutdownFailure())
    }
    return await registerAdmitted(
      request,
      admissionGeneration: accountAdmissionGeneration(for: request.accountID)
    )
  }

  private func registerAdmitted(
    _ request: ProviderAccountRegistrationRequest,
    admissionGeneration: UUID
  ) async -> ProviderAccountEventStream {
    guard !revokingAccounts.contains(request.accountID) else {
      return ProviderAccountEventStream.failed(
        ProviderFailure(
          code: .accountUnavailable,
          message: "provider account is being revoked"
        )
      )
    }
    guard accountAdmissionGeneration(for: request.accountID) == admissionGeneration else {
      return ProviderAccountEventStream.failed(
        ProviderFailure(
          code: .accountUnavailable,
          message: "provider account registration was invalidated by account revocation"
        )
      )
    }
    return await accountSupervisor.register(
      request,
      admissionGeneration: admissionGeneration
    )
  }

  public func cancelRegistration(accountID: ProviderAccountID) async {
    await accountSupervisor.cancel(accountID: accountID)
  }

  /// Revokes an account fail-closed: new executions are rejected, active
  /// executions are cancelled and joined, and only then is the credential removed.
  public func revoke(accountID: ProviderAccountID) async throws {
    try beginControlOperation()
    defer { endControlOperation() }
    guard revokingAccounts.insert(accountID).inserted else {
      throw ProviderFailure(
        code: .invalidRequest,
        message: "provider account revocation is already active"
      )
    }
    let admissionGeneration = UUID()
    accountAdmissionGenerations[accountID] = admissionGeneration
    defer { revokingAccounts.remove(accountID) }

    await executionSupervisor.cancelAndJoin(accountID: accountID)
    try await accountSupervisor.revoke(
      accountID: accountID,
      admissionGeneration: admissionGeneration
    )
  }

  public func registerOpenRouterOAuth(
    _ request: OpenRouterOAuthRegistrationRequest,
    using authorizationSession: any ProviderAuthorizationSession
  ) async throws -> ProviderAccountEventStream {
    try beginControlOperation()
    defer { endControlOperation() }
    try requireAvailable(request.accountID)
    guard consumedOAuthStates.consume(request.pkce.state) else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth state has already been consumed"
      )
    }
    let admissionGeneration = accountAdmissionGeneration(for: request.accountID)

    let registration = try await openRouterOAuthBroker.authorize(
      request,
      using: authorizationSession
    )
    try Task.checkCancellation()
    return await registerAdmitted(
      registration,
      admissionGeneration: admissionGeneration
    )
  }

  public func inspect(
    accountID: ProviderAccountID
  ) async throws -> ProviderAccountInspection {
    try beginControlOperation()
    defer { endControlOperation() }
    try requireAvailable(accountID)
    return try await accountSupervisor.inspect(accountID: accountID)
  }

  public func models(
    accountID: ProviderAccountID
  ) async throws -> ProviderModelCatalogResult {
    try beginControlOperation()
    defer { endControlOperation() }
    try requireAvailable(accountID)
    return try await accountSupervisor.models(accountID: accountID)
  }

  public func execute(_ request: ProviderTurnRequest) async -> ProviderEventStream {
    guard lifecycle == .running else {
      return ProviderEventStream.failed(
        ProviderFailure(
          code: .cancelled,
          message: "provider runtime is shutting down",
          requestID: request.id
        )
      )
    }
    do {
      try requireAvailable(request.selection.accountID)
      return await executionSupervisor.execute(request)
    } catch let failure as ProviderFailure {
      return ProviderEventStream.failed(
        ProviderFailure(
          code: failure.code,
          message: failure.message,
          providerStatusCode: failure.providerStatusCode,
          retryAfterMilliseconds: failure.retryAfterMilliseconds,
          requestID: request.id
        )
      )
    } catch {
      return ProviderEventStream.failed(
        ProviderWireError.failure(error, requestID: request.id)
      )
    }
  }

  public func cancel(_ requestID: ProviderRequestID) async {
    await executionSupervisor.cancel(requestID)
  }

  public func shutdown() async {
    switch lifecycle {
    case .shutDown:
      return
    case .shuttingDown:
      await withCheckedContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    case .running:
      lifecycle = .shuttingDown
    }

    if activeControlOperations > 0 {
      await withCheckedContinuation { continuation in
        controlDrainWaiters.append(continuation)
      }
    }
    await accountSupervisor.shutdown()
    await executionSupervisor.shutdown()
    lifecycle = .shutDown
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func beginControlOperation() throws {
    guard lifecycle == .running else { throw shutdownFailure() }
    activeControlOperations += 1
  }

  private func endControlOperation() {
    precondition(activeControlOperations > 0)
    activeControlOperations -= 1
    guard activeControlOperations == 0 else { return }
    let waiters = controlDrainWaiters
    controlDrainWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func shutdownFailure() -> ProviderFailure {
    ProviderFailure(code: .cancelled, message: "provider runtime is shutting down")
  }

  private func requireAvailable(_ accountID: ProviderAccountID) throws {
    guard !revokingAccounts.contains(accountID) else {
      throw ProviderFailure(
        code: .accountUnavailable,
        message: "provider account is being revoked"
      )
    }
  }

  private func accountAdmissionGeneration(for accountID: ProviderAccountID) -> UUID {
    accountAdmissionGenerations[accountID] ?? initialAdmissionGeneration
  }
}
