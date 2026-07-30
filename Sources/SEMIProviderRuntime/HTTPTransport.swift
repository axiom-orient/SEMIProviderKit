import Foundation
import SEMIProviderCore

package enum ProviderTransportError: Error, Equatable, Sendable {
  case invalidResponse
  case responseTooLarge
  case consumerBackpressureExceeded
  case transport(String)
}

package struct ProviderHTTPRequest: Sendable {
  package let urlRequest: URLRequest
  package let maximumResponseBytes: Int
  package let chunkCapacity: Int

  package init(
    urlRequest: URLRequest,
    maximumResponseBytes: Int,
    chunkCapacity: Int = 64
  ) {
    precondition(maximumResponseBytes > 0)
    precondition(chunkCapacity >= 2)
    self.urlRequest = urlRequest
    self.maximumResponseBytes = maximumResponseBytes
    self.chunkCapacity = chunkCapacity
  }
}

package struct ProviderHTTPResponse: Sendable {
  package let statusCode: Int
  package let headers: [String: String]
  package let body: ProviderHTTPBodyStream
  package let cancel: @Sendable () -> Void
  package let waitForTermination: @Sendable () async -> Void

  package init(
    statusCode: Int,
    headers: [String: String],
    body: ProviderHTTPBodyStream,
    cancel: @escaping @Sendable () -> Void,
    waitForTermination: @escaping @Sendable () async -> Void = {}
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.cancel = cancel
    self.waitForTermination = waitForTermination
  }
}

package struct ProviderHTTPUnaryResponse: Sendable {
  package let statusCode: Int
  package let headers: [String: String]
  package let body: Data
}

package protocol ProviderHTTPTransport: Sendable {
  func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse
}

extension ProviderHTTPTransport {
  package func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPUnaryResponse {
    try Task.checkCancellation()
    let response = try await open(request)
    var data = Data()
    do {
      for try await chunk in response.body {
        try Task.checkCancellation()
        let (nextCount, overflowed) = data.count.addingReportingOverflow(chunk.count)
        guard !overflowed, nextCount <= request.maximumResponseBytes else {
          throw ProviderTransportError.responseTooLarge
        }
        data.append(chunk)
      }
      try Task.checkCancellation()
    } catch {
      response.cancel()
      await response.waitForTermination()
      throw error
    }
    await response.waitForTermination()
    return .init(statusCode: response.statusCode, headers: response.headers, body: data)
  }
}

package struct ProviderHTTPBodyStream: AsyncSequence, Sendable {
  package typealias Element = Data
  private let stream: AsyncThrowingStream<Data, any Error>

  package init(stream: AsyncThrowingStream<Data, any Error>) {
    self.stream = stream
  }

  package func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(iterator: stream.makeAsyncIterator())
  }

  package struct AsyncIterator: AsyncIteratorProtocol {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator

    fileprivate init(iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator) {
      self.iterator = iterator
    }

    package mutating func next() async throws -> Data? {
      try await iterator.next()
    }
  }
}

package struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
  package init() {}

  package func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
    let operation = StreamingHTTPOperation(request: request)
    return try await operation.start()
  }
}

private final class StreamingHTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private enum State {
    case idle
    case awaitingResponse
    case streaming
    case terminal
  }

  private let request: ProviderHTTPRequest
  private let lock = NSLock()
  private let termination = TransportTerminationSignal()
  private let pair:
    (
      stream: AsyncThrowingStream<Data, any Error>,
      continuation: AsyncThrowingStream<Data, any Error>.Continuation
    )
  private var state: State = .idle
  private var responseContinuation: CheckedContinuation<ProviderHTTPResponse, any Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var totalBytes = 0

  init(request: ProviderHTTPRequest) {
    self.request = request
    self.pair = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(request.chunkCapacity)
    )
    super.init()
    pair.continuation.onTermination = { [weak self] _ in self?.cancel() }
  }

  func start() async throws -> ProviderHTTPResponse {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let reservationError: (any Error)? = lock.withLock {
          switch state {
          case .idle:
            state = .awaitingResponse
            responseContinuation = continuation
            return nil
          case .terminal:
            return CancellationError()
          case .awaitingResponse, .streaming:
            return ProviderTransportError.transport("HTTP operation was started more than once")
          }
        }
        if let reservationError {
          continuation.resume(throwing: reservationError)
          return
        }

        let queue = OperationQueue()
        queue.name = "SEMIProviderKit.HTTP.\(UUID().uuidString)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(
          configuration: configuration,
          delegate: self,
          delegateQueue: queue
        )
        let task = session.dataTask(with: request.urlRequest)
        let shouldStart = lock.withLock { () -> Bool in
          guard state == .awaitingResponse, responseContinuation != nil else { return false }
          self.session = session
          self.task = task
          return true
        }
        if shouldStart {
          task.resume()
        } else {
          task.cancel()
          session.invalidateAndCancel()
        }
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    let cleanup = lock.withLock {
      () -> (
        URLSessionDataTask?, URLSession?, CheckedContinuation<ProviderHTTPResponse, any Error>?
      ) in
      guard state != .terminal else { return (nil, nil, nil) }
      state = .terminal
      let task = self.task
      let session = self.session
      let continuation = responseContinuation
      self.task = nil
      self.session = nil
      responseContinuation = nil
      return (task, session, continuation)
    }
    cleanup.0?.cancel()
    cleanup.1?.invalidateAndCancel()
    cleanup.2?.resume(throwing: CancellationError())
    pair.continuation.finish(throwing: CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      finishBeforeResponse(error: ProviderTransportError.invalidResponse)
      completionHandler(.cancel)
      return
    }

    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      guard let key = pair.key as? String else { return }
      result[key.lowercased()] = String(describing: pair.value)
    }
    let continuation = lock.withLock {
      () -> CheckedContinuation<ProviderHTTPResponse, any Error>? in
      guard state == .awaitingResponse else { return nil }
      state = .streaming
      let continuation = responseContinuation
      responseContinuation = nil
      return continuation
    }
    guard let continuation else {
      completionHandler(.cancel)
      return
    }
    continuation.resume(
      returning: ProviderHTTPResponse(
        statusCode: http.statusCode,
        headers: headers,
        body: ProviderHTTPBodyStream(stream: pair.stream),
        cancel: { [weak self] in self?.cancel() },
        waitForTermination: { [termination] in await termination.wait() }
      )
    )
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    _ = session
    _ = task
    _ = response
    _ = request
    // Provider credentials are scoped to the exact configured endpoint.
    // Redirects must be inspected and configured explicitly rather than
    // forwarding an authenticated request to a different origin.
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    enum Delivery {
      case ignore
      case data
      case fail(ProviderTransportError)
    }

    let delivery: Delivery = lock.withLock {
      guard state == .streaming else { return .ignore }
      let (next, overflowed) = totalBytes.addingReportingOverflow(data.count)
      guard !overflowed, next <= request.maximumResponseBytes else {
        state = .terminal
        task = nil
        self.session = nil
        return .fail(.responseTooLarge)
      }
      totalBytes = next
      return .data
    }

    switch delivery {
    case .ignore:
      return
    case .fail(let error):
      pair.continuation.finish(throwing: error)
      dataTask.cancel()
      session.invalidateAndCancel()
      return
    case .data:
      break
    }

    // AsyncThrowingStream may synchronously invoke onTermination. Yielding
    // while the operation lock is held would therefore permit self-deadlock.
    let result = pair.continuation.yield(data)

    switch result {
    case .enqueued:
      break
    case .dropped:
      finishStreaming(error: ProviderTransportError.consumerBackpressureExceeded)
      dataTask.cancel()
      session.invalidateAndCancel()
    case .terminated:
      dataTask.cancel()
      session.invalidateAndCancel()
    @unknown default:
      finishStreaming(error: ProviderTransportError.transport("unknown stream yield result"))
      dataTask.cancel()
      session.invalidateAndCancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let completion = lock.withLock {
      () -> (State, CheckedContinuation<ProviderHTTPResponse, any Error>?) in
      let previous = state
      guard previous != .terminal else { return (.terminal, nil) }
      state = .terminal
      let continuation = responseContinuation
      responseContinuation = nil
      self.task = nil
      self.session = nil
      return (previous, continuation)
    }

    session.finishTasksAndInvalidate()
    defer { Task { [termination] in await termination.finish() } }
    if completion.0 == .awaitingResponse {
      completion.1?.resume(throwing: error ?? ProviderTransportError.invalidResponse)
      pair.continuation.finish(throwing: error ?? ProviderTransportError.invalidResponse)
      return
    }
    if let error {
      pair.continuation.finish(throwing: error)
    } else {
      pair.continuation.finish()
    }
  }

  // A session can be invalidated without delivering a task completion. Without
  // this the termination signal would never fire and `waitForTermination` would
  // block the owning execution forever, so invalidation is a terminal edge too.
  func urlSession(
    _ session: URLSession,
    didBecomeInvalidWithError error: (any Error)?
  ) {
    _ = session
    let invalidation =
      error ?? ProviderTransportError.transport("HTTP session was invalidated")
    let continuation = lock.withLock {
      () -> CheckedContinuation<ProviderHTTPResponse, any Error>? in
      guard state != .terminal else { return nil }
      state = .terminal
      let continuation = responseContinuation
      responseContinuation = nil
      task = nil
      self.session = nil
      return continuation
    }
    continuation?.resume(throwing: invalidation)
    pair.continuation.finish(throwing: invalidation)
    Task { [termination] in await termination.finish() }
  }

  private func finishBeforeResponse(error: any Error) {
    let continuation = lock.withLock {
      () -> CheckedContinuation<ProviderHTTPResponse, any Error>? in
      guard state != .terminal else { return nil }
      state = .terminal
      let continuation = responseContinuation
      responseContinuation = nil
      task = nil
      session = nil
      return continuation
    }
    continuation?.resume(throwing: error)
    pair.continuation.finish(throwing: error)
  }

  private func finishStreaming(error: any Error) {
    let shouldFinish = lock.withLock { () -> Bool in
      guard state != .terminal else { return false }
      state = .terminal
      task = nil
      session = nil
      responseContinuation = nil
      return true
    }
    if shouldFinish { pair.continuation.finish(throwing: error) }
  }
}

private actor TransportTerminationSignal {
  private var finished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if finished { return }
    await withCheckedContinuation { continuation in
      if finished {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func finish() {
    guard !finished else { return }
    finished = true
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for waiter in pending { waiter.resume() }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
