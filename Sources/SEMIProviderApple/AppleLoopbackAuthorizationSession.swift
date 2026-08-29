import Foundation
import SEMIProviderCore

#if os(macOS)
  import AppKit
  import Network
#endif

package struct HTTPHeaderTerminatorScanner: Sendable {
  private var matchedByteCount = 0
  package private(set) var scannedByteCount = 0

  package init() {}

  package mutating func feed(_ data: Data) -> Bool {
    for byte in data {
      scannedByteCount += 1
      switch matchedByteCount {
      case 0:
        matchedByteCount = byte == 0x0D ? 1 : 0
      case 1:
        if byte == 0x0A {
          matchedByteCount = 2
        } else {
          matchedByteCount = byte == 0x0D ? 1 : 0
        }
      case 2:
        matchedByteCount = byte == 0x0D ? 3 : 0
      case 3:
        if byte == 0x0A {
          matchedByteCount = 4
          return true
        }
        matchedByteCount = byte == 0x0D ? 1 : 0
      default:
        return true
      }
    }
    return matchedByteCount == 4
  }
}

#if os(macOS)
  /// Native-app OAuth session for providers that accept loopback callbacks.
  /// The listener is bound before the browser opens, accepts one bounded HTTP
  /// callback while authorization is active, and closes before publishing it.
  public actor AppleLoopbackAuthorizationSession: ProviderAuthorizationSession {
    public struct Prepared: Sendable {
      /// A bound listener. Call `session.authorize(_:)` or `session.cancel()` to
      /// release its loopback port.
      public let session: AppleLoopbackAuthorizationSession
      public let callbackURL: URL

      package init(session: AppleLoopbackAuthorizationSession, callbackURL: URL) {
        self.session = session
        self.callbackURL = callbackURL
      }
    }

    private static let maximumRequestBytes = 32 * 1_024
    private static let maximumConcurrentConnections = 8
    private static let readinessTimeout: Duration = .seconds(10)
    private static let authorizationTimeout: Duration = .seconds(300)
    private static let requestHeaderTimeout: DispatchTimeInterval = .seconds(10)

    private let listener: NWListener
    private let callbackPath: String
    private let queue: DispatchQueue
    private var callbackURLValue: URL?
    private var readinessWaiter: CheckedContinuation<URL, any Error>?
    private var callbackWaiter: CheckedContinuation<ProviderAuthorizationResult, any Error>?
    private var readinessTimeoutTask: Task<Void, Never>?
    private var authorizationTimeoutTask: Task<Void, Never>?
    private var authorizationActive = false
    private var authorizationState: String?
    private var activeConnections: [UUID: NWConnection] = [:]
    private var finished = false

    private init(listener: NWListener, callbackPath: String) {
      self.listener = listener
      self.callbackPath = callbackPath
      self.queue = DispatchQueue(label: "com.semi.providerkit.oauth.loopback")
    }

    public static func prepare(
      callbackPath: String = "/oauth/openrouter"
    ) async throws -> Prepared {
      guard callbackPath.hasPrefix("/"),
        callbackPath.utf8.count <= 512,
        !callbackPath.contains("?"),
        !callbackPath.contains("#"),
        !callbackPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(code: .invalidValue, message: "loopback callback path is invalid")
      }
      let listener: NWListener
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
          host: NWEndpoint.Host("127.0.0.1"),
          port: .any
        )
        listener = try NWListener(using: parameters, on: .any)
      } catch {
        throw ProviderFailure(
          code: .authenticationFailed,
          message: "loopback OAuth listener could not be created"
        )
      }
      let session = AppleLoopbackAuthorizationSession(
        listener: listener,
        callbackPath: callbackPath
      )
      let callbackURL = try await withTaskCancellationHandler {
        try await session.start()
      } onCancel: {
        Task { await session.cancel() }
      }
      return Prepared(session: session, callbackURL: callbackURL)
    }

    public func authorize(
      _ request: ProviderAuthorizationRequest
    ) async throws -> ProviderAuthorizationResult {
      try Task.checkCancellation()
      guard !finished, callbackURLValue != nil else {
        throw ProviderFailure(
          code: .authenticationFailed,
          message: "loopback OAuth listener is not available"
        )
      }
      guard !authorizationActive, callbackWaiter == nil else {
        throw ProviderFailure(
          code: .invalidRequest,
          message: "a loopback authorization is already active"
        )
      }
      try Self.validateLoopbackAuthorizationRequest(request)

      authorizationState = request.state
      authorizationActive = true
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          callbackWaiter = continuation
          authorizationTimeoutTask = Task { [weak self] in
            do {
              try await Task.sleep(for: Self.authorizationTimeout)
              await self?.fail(
                ProviderFailure(
                  code: .timedOut,
                  message: "loopback OAuth authorization timed out"
                )
              )
            } catch {
              // Cancellation is the expected completion path.
            }
          }
          Task { [weak self] in
            guard let self, await self.authorizationCanOpenBrowser() else { return }
            let opened = await MainActor.run {
              NSWorkspace.shared.open(request.authorizationURL)
            }
            guard !opened else { return }
            await self.fail(
              ProviderFailure(
                code: .authenticationFailed,
                message: "system browser could not open the authorization URL"
              )
            )
          }
        }
      } onCancel: {
        Task { await self.cancel() }
      }
    }

    /// Validates requirements that are specific to this loopback session.
    ///
    /// OAuth providers choose how they carry the redirect URL. In particular,
    /// OpenRouter's documented PKCE URL has a `callback_url` query item rather
    /// than a top-level `state`. The callback parser validates the expected state
    /// after the provider redirects to the bound loopback listener.
    package static func validateLoopbackAuthorizationRequest(
      _ request: ProviderAuthorizationRequest
    ) throws {
      guard request.callbackScheme.lowercased() == "http" else {
        throw ProviderFailure(
          code: .invalidRequest,
          message: "loopback authorization requires an HTTP callback"
        )
      }
    }

    public func cancel() async {
      guard !finished else { return }
      fail(
        ProviderFailure(
          code: .cancelled,
          message: "loopback OAuth authorization was cancelled"
        )
      )
    }

    private func start() async throws -> URL {
      if let callbackURLValue { return callbackURLValue }
      guard !finished, readinessWaiter == nil else {
        throw ProviderFailure(
          code: .invalidRequest,
          message: "loopback OAuth listener startup is already active"
        )
      }
      return try await withCheckedThrowingContinuation { continuation in
        readinessWaiter = continuation
        readinessTimeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: Self.readinessTimeout)
            await self?.fail(
              ProviderFailure(
                code: .timedOut,
                message: "loopback OAuth listener did not become ready"
              )
            )
          } catch {
            // Cancellation is the expected completion path.
          }
        }
        listener.stateUpdateHandler = { [weak self] state in
          Task { await self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
          Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)
      }
    }

    private func authorizationCanOpenBrowser() -> Bool {
      !finished && authorizationActive && callbackWaiter != nil
    }

    private func handleListenerState(_ state: NWListener.State) {
      switch state {
      case .ready:
        guard callbackURLValue == nil, let port = listener.port else { return }
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(callbackPath)") else {
          fail(
            ProviderFailure(
              code: .internalInvariant,
              message: "loopback OAuth callback URL could not be constructed"
            )
          )
          return
        }
        callbackURLValue = url
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let waiter = readinessWaiter
        readinessWaiter = nil
        waiter?.resume(returning: url)
      case .failed:
        fail(
          ProviderFailure(
            code: .authenticationFailed,
            message: "loopback OAuth listener failed"
          )
        )
      case .cancelled:
        if !finished {
          fail(
            ProviderFailure(
              code: .cancelled,
              message: "loopback OAuth listener was cancelled"
            )
          )
        }
      case .setup, .waiting:
        break
      @unknown default:
        fail(
          ProviderFailure(
            code: .authenticationFailed,
            message: "loopback OAuth listener entered an unknown state"
          )
        )
      }
    }

    private func accept(_ connection: NWConnection) {
      guard !finished else {
        connection.cancel()
        return
      }
      guard activeConnections.count < Self.maximumConcurrentConnections else {
        connection.cancel()
        return
      }
      let connectionID = UUID()
      activeConnections[connectionID] = connection
      let reader = LoopbackHTTPRequestReader(
        connection: connection,
        maximumBytes: Self.maximumRequestBytes,
        timeout: Self.requestHeaderTimeout,
        callback: { [weak self] result in
          Task {
            await self?.handleRequest(
              result,
              connectionID: connectionID,
              connection: connection
            )
          }
        }
      )
      reader.start(on: queue)
    }

    private func handleRequest(
      _ result: Result<Data, any Error>,
      connectionID: UUID,
      connection: NWConnection
    ) async {
      defer { activeConnections.removeValue(forKey: connectionID) }
      guard !finished else {
        connection.cancel()
        return
      }
      guard authorizationActive, callbackWaiter != nil, let authorizationState else {
        await sendHTTPResponse(
          status: "409 Conflict",
          body: "SEMI authorization is not active.",
          connection: connection
        )
        return
      }
      switch result {
      case .failure:
        await sendHTTPResponse(
          status: "400 Bad Request",
          body: "Authorization callback could not be read.",
          connection: connection
        )
      case .success(let data):
        do {
          let callback = try LoopbackOAuthCallbackParser.parse(
            data,
            baseURL: try requireCallbackURL(),
            callbackPath: callbackPath,
            expectedState: authorizationState,
            maximumBytes: Self.maximumRequestBytes
          )
          await sendHTTPResponse(
            status: "200 OK",
            body: "SEMI authorization completed. You can close this window.",
            connection: connection
          )
          publish(callback)
        } catch {
          await sendHTTPResponse(
            status: "400 Bad Request",
            body: "Authorization callback was rejected.",
            connection: connection
          )
        }
      }
    }

    private func requireCallbackURL() throws -> URL {
      guard let callbackURLValue else {
        throw ProviderFailure(
          code: .internalInvariant,
          message: "loopback OAuth callback URL is unavailable"
        )
      }
      return callbackURLValue
    }

    private func sendHTTPResponse(
      status: String,
      body: String,
      connection: NWConnection
    ) async {
      let escaped =
        body
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
      let html = "<!doctype html><meta charset=\"utf-8\"><title>SEMI</title><p>\(escaped)</p>"
      let data = Data(html.utf8)
      let header =
        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
      let payload = Data(header.utf8) + data
      await withCheckedContinuation { continuation in
        connection.send(
          content: payload,
          completion: .contentProcessed { _ in
            connection.cancel()
            continuation.resume()
          })
      }
    }

    private func publish(_ callbackURL: URL) {
      guard !finished, let waiter = callbackWaiter else { return }
      callbackWaiter = nil
      authorizationTimeoutTask?.cancel()
      authorizationTimeoutTask = nil
      authorizationActive = false
      authorizationState = nil
      finishListener()
      waiter.resume(returning: ProviderAuthorizationResult(callbackURL: callbackURL))
    }

    private func fail(_ error: any Error) {
      guard !finished else { return }
      readinessTimeoutTask?.cancel()
      readinessTimeoutTask = nil
      authorizationTimeoutTask?.cancel()
      authorizationTimeoutTask = nil
      authorizationActive = false
      authorizationState = nil
      let ready = readinessWaiter
      readinessWaiter = nil
      let callback = callbackWaiter
      callbackWaiter = nil
      finishListener()
      ready?.resume(throwing: error)
      callback?.resume(throwing: error)
    }

    private func finishListener() {
      guard !finished else { return }
      finished = true
      readinessTimeoutTask?.cancel()
      readinessTimeoutTask = nil
      authorizationTimeoutTask?.cancel()
      authorizationTimeoutTask = nil
      listener.stateUpdateHandler = nil
      listener.newConnectionHandler = nil
      listener.cancel()
      let connections = activeConnections.values
      activeConnections.removeAll(keepingCapacity: false)
      for connection in connections { connection.cancel() }
    }
  }

  private final class LoopbackHTTPRequestReader: @unchecked Sendable {
    private let connection: NWConnection
    private let maximumBytes: Int
    private let timeout: DispatchTimeInterval
    private let callback: @Sendable (Result<Data, any Error>) -> Void
    private var buffer = Data()
    private var headerTerminatorScanner = HTTPHeaderTerminatorScanner()
    private var timeoutSource: DispatchSourceTimer?
    private var completed = false

    init(
      connection: NWConnection,
      maximumBytes: Int,
      timeout: DispatchTimeInterval,
      callback: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) {
      self.connection = connection
      self.maximumBytes = maximumBytes
      self.timeout = timeout
      self.callback = callback
    }

    func start(on queue: DispatchQueue) {
      queue.async { [self] in
        startOnQueue(queue)
      }
    }

    private func startOnQueue(_ queue: DispatchQueue) {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler { [self] in
        complete(
          .failure(
            ProviderFailure(
              code: .timedOut,
              message: "loopback callback HTTP headers timed out"
            )
          )
        )
      }
      timeoutSource = timer
      timer.resume()
      connection.start(queue: queue)
      receive()
    }

    private func receive() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1_024) {
        [self] data, _, isComplete, error in
        guard !completed else { return }
        if let error {
          complete(.failure(error))
          return
        }
        if let data, !data.isEmpty {
          buffer.append(data)
          if buffer.count > maximumBytes {
            complete(
              .failure(
                ProviderFailure(
                  code: .responseTooLarge,
                  message: "loopback callback request exceeds its size limit"
                )
              )
            )
            return
          }
          if headerTerminatorScanner.feed(data) {
            complete(.success(buffer))
            return
          }
        }
        if isComplete {
          complete(
            .failure(
              ProviderFailure(
                code: .authenticationFailed,
                message: "loopback callback ended before the HTTP headers completed"
              )
            )
          )
          return
        }
        receive()
      }
    }

    private func complete(_ result: Result<Data, any Error>) {
      guard !completed else { return }
      completed = true
      timeoutSource?.cancel()
      timeoutSource = nil
      callback(result)
    }
  }
#endif
