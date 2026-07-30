import Foundation

package enum ProviderMailboxSendResult: Sendable {
  case accepted
  case coalesced
  case overflow
  case closed
}

package actor ProviderEventMailbox {
  private final class TextBatch {
    var chunks: [String]
    var scalarCount: Int

    init(_ text: String, scalarCount: Int) {
      self.chunks = [text]
      self.scalarCount = scalarCount
    }

    func append(_ text: String, scalarCount: Int) {
      chunks.append(text)
      self.scalarCount = scalarCount
    }

    func joined() -> String {
      chunks.joined()
    }
  }

  private enum BufferedEvent {
    case event(ProviderTurnEvent)
    case text(TextBatch)
  }

  private let capacity: Int
  private let maximumCoalescedTextScalars: Int
  private var buffer: [BufferedEvent] = []
  private var head = 0
  private var waiter: CheckedContinuation<ProviderTurnEvent?, Never>?
  private var consumerID: UUID?
  private var terminalCommitted = false
  private var drained = false

  package init(capacity: Int, maximumCoalescedTextScalars: Int) {
    precondition(capacity >= 2)
    precondition(maximumCoalescedTextScalars > 0)
    self.capacity = capacity
    self.maximumCoalescedTextScalars = maximumCoalescedTextScalars
  }

  package func send(_ event: ProviderTurnEvent) -> ProviderMailboxSendResult {
    guard !terminalCommitted, !drained else { return .closed }
    if case .terminal = event {
      return commitTerminal(event) ? .accepted : .closed
    }

    if let waiter {
      self.waiter = nil
      waiter.resume(returning: event)
      return .accepted
    }

    if case .textDelta(let incoming) = event,
      let lastIndex = buffer.indices.last,
      lastIndex >= head,
      case .text(let batch) = buffer[lastIndex]
    {
      let incomingCount = incoming.unicodeScalars.count
      let (nextCount, overflowed) = batch.scalarCount.addingReportingOverflow(incomingCount)
      if !overflowed, nextCount <= maximumCoalescedTextScalars {
        batch.append(incoming, scalarCount: nextCount)
        return .coalesced
      }
    }

    // Reserve one slot for the exactly-once terminal event. Text chunks are
    // retained as a batch and joined only when consumed, avoiding repeated
    // whole-string copies for token-sized deltas.
    guard count < capacity - 1 else { return .overflow }
    switch event {
    case .textDelta(let text):
      buffer.append(.text(TextBatch(text, scalarCount: text.unicodeScalars.count)))
    case .started, .toolCall:
      buffer.append(.event(event))
    case .terminal:
      return .closed
    }
    return .accepted
  }

  @discardableResult
  package func finish(with terminal: ProviderTerminal) -> Bool {
    commitTerminal(.terminal(terminal))
  }

  package func next(consumerID requestedConsumerID: UUID) async -> ProviderTurnEvent? {
    if let consumerID, consumerID != requestedConsumerID {
      return .terminal(.failed(Self.multipleConsumerFailure))
    }
    consumerID = requestedConsumerID
    if head < buffer.count {
      let buffered = buffer[head]
      head += 1
      compactIfNeeded()
      let event: ProviderTurnEvent
      switch buffered {
      case .event(let value): event = value
      case .text(let batch): event = .textDelta(batch.joined())
      }
      if case .terminal = event { drained = true }
      return event
    }
    if terminalCommitted || drained { return nil }
    guard waiter == nil else {
      return .terminal(.failed(Self.concurrentNextFailure))
    }
    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  private static let multipleConsumerFailure = ProviderFailure(
    code: .invalidRequest,
    message: "ProviderEventStream supports exactly one consumer"
  )
  private static let concurrentNextFailure = ProviderFailure(
    code: .invalidRequest,
    message: "ProviderEventStream does not permit concurrent next calls"
  )

  private var count: Int { buffer.count - head }

  private func commitTerminal(_ event: ProviderTurnEvent) -> Bool {
    guard !terminalCommitted, !drained else { return false }
    terminalCommitted = true
    if let waiter {
      self.waiter = nil
      drained = true
      waiter.resume(returning: event)
      return true
    }

    compactAll()
    precondition(buffer.count < capacity, "terminal slot must remain reserved")
    buffer.append(.event(event))
    return true
  }

  private func compactIfNeeded() {
    guard head > 0, head >= 64, head * 2 >= buffer.count else { return }
    buffer.removeFirst(head)
    head = 0
  }

  private func compactAll() {
    guard head > 0 else { return }
    buffer.removeFirst(head)
    head = 0
  }
}

public struct ProviderEventStream: AsyncSequence, Sendable {
  public typealias Element = ProviderTurnEvent

  private let mailbox: ProviderEventMailbox

  package init(mailbox: ProviderEventMailbox) {
    self.mailbox = mailbox
  }

  package static func failed(_ failure: ProviderFailure) -> ProviderEventStream {
    let (stream, sink) = make()
    Task { await sink.finish(with: .failed(failure)) }
    return stream
  }

  package static func make(
    capacity: Int = 64,
    maximumCoalescedTextScalars: Int = 16_384
  ) -> (ProviderEventStream, ProviderEventSink) {
    let mailbox = ProviderEventMailbox(
      capacity: capacity,
      maximumCoalescedTextScalars: maximumCoalescedTextScalars
    )
    return (ProviderEventStream(mailbox: mailbox), ProviderEventSink(mailbox: mailbox))
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(mailbox: mailbox)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let mailbox: ProviderEventMailbox
    private let consumerID: UUID
    private var ended = false

    package init(mailbox: ProviderEventMailbox) {
      self.mailbox = mailbox
      self.consumerID = UUID()
    }

    public mutating func next() async -> ProviderTurnEvent? {
      guard !ended else { return nil }
      let event = await mailbox.next(consumerID: consumerID)
      if event == nil {
        ended = true
      } else if case .terminal = event {
        ended = true
      }
      return event
    }
  }
}

package struct ProviderEventSink: Sendable {
  private let mailbox: ProviderEventMailbox

  package init(mailbox: ProviderEventMailbox) {
    self.mailbox = mailbox
  }

  package func send(_ event: ProviderTurnEvent) async -> ProviderMailboxSendResult {
    await mailbox.send(event)
  }

  @discardableResult
  package func finish(with terminal: ProviderTerminal) async -> Bool {
    await mailbox.finish(with: terminal)
  }
}

package actor ProviderAccountEventMailbox {
  private let capacity: Int
  private var buffer: [ProviderAccountPublicEvent] = []
  private var head = 0
  private var waiter: CheckedContinuation<ProviderAccountPublicEvent?, Never>?
  private var consumerID: UUID?
  private var finished = false

  package init(capacity: Int) {
    precondition(capacity >= 2)
    self.capacity = capacity
  }

  package func send(_ event: ProviderAccountPublicEvent, finishes: Bool) -> Bool {
    guard !finished else { return false }
    if let waiter {
      self.waiter = nil
      if finishes { finished = true }
      waiter.resume(returning: event)
      return true
    }

    let count = buffer.count - head
    if finishes {
      guard count < capacity else { return false }
    } else {
      // Preserve one slot for the terminal account event so slow consumers
      // cannot turn a completed registration into an unobservable outcome.
      guard count < capacity - 1 else { return false }
    }
    buffer.append(event)
    if finishes { finished = true }
    return true
  }

  package func next(consumerID requestedConsumerID: UUID) async -> ProviderAccountPublicEvent? {
    if let consumerID, consumerID != requestedConsumerID {
      return .failed(Self.multipleConsumerFailure)
    }
    consumerID = requestedConsumerID
    if head < buffer.count {
      let event = buffer[head]
      head += 1
      if head >= 64, head * 2 >= buffer.count {
        buffer.removeFirst(head)
        head = 0
      }
      return event
    }
    if finished { return nil }
    guard waiter == nil else { return .failed(Self.concurrentNextFailure) }
    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  private static let multipleConsumerFailure = ProviderFailure(
    code: .invalidRequest,
    message: "ProviderAccountEventStream supports exactly one consumer"
  )
  private static let concurrentNextFailure = ProviderFailure(
    code: .invalidRequest,
    message: "ProviderAccountEventStream does not permit concurrent next calls"
  )
}

public struct ProviderAccountEventStream: AsyncSequence, Sendable {
  public typealias Element = ProviderAccountPublicEvent
  private let mailbox: ProviderAccountEventMailbox

  package init(mailbox: ProviderAccountEventMailbox) {
    self.mailbox = mailbox
  }

  package static func failed(_ failure: ProviderFailure) -> ProviderAccountEventStream {
    let (stream, sink) = make()
    Task { _ = await sink.send(.failed(failure)) }
    return stream
  }

  package static func make(capacity: Int = 16) -> (
    ProviderAccountEventStream,
    ProviderAccountEventSink
  ) {
    let mailbox = ProviderAccountEventMailbox(capacity: capacity)
    return (
      ProviderAccountEventStream(mailbox: mailbox),
      ProviderAccountEventSink(mailbox: mailbox)
    )
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(mailbox: mailbox)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let mailbox: ProviderAccountEventMailbox
    private let consumerID: UUID
    private var ended = false

    package init(mailbox: ProviderAccountEventMailbox) {
      self.mailbox = mailbox
      self.consumerID = UUID()
    }

    public mutating func next() async -> ProviderAccountPublicEvent? {
      guard !ended else { return nil }
      let event = await mailbox.next(consumerID: consumerID)
      if let event {
        switch event {
        case .ready, .failed, .recoveryRequired: ended = true
        case .staging, .verifying, .activating: break
        }
      } else {
        ended = true
      }
      return event
    }
  }
}

package struct ProviderAccountEventSink: Sendable {
  private let mailbox: ProviderAccountEventMailbox

  package init(mailbox: ProviderAccountEventMailbox) {
    self.mailbox = mailbox
  }

  package func send(_ event: ProviderAccountPublicEvent) async -> Bool {
    let finishes: Bool
    switch event {
    case .ready, .failed, .recoveryRequired: finishes = true
    case .staging, .verifying, .activating: finishes = false
    }
    return await mailbox.send(event, finishes: finishes)
  }
}
