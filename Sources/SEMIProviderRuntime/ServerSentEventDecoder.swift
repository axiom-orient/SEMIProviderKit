import Foundation
import SEMIProviderCore

package struct ServerSentEvent: Equatable, Sendable {
  package let event: String?
  package let data: String
  package let id: String?
  package let retryMilliseconds: UInt64?
}

package struct ServerSentEventDecoder: Sendable {
  private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

  private let maximumLineBytes: Int
  private let maximumEventBytes: Int
  private var lineBytes = Data()
  private var streamPrefix = Data()
  private var checkingByteOrderMark = true
  private var pendingLineFeedAfterCarriageReturn = false
  private var eventName: String?
  private var dataLines: [String] = []
  private var dataByteCount = 0
  private var eventID: String?
  private var retryMilliseconds: UInt64?
  package private(set) var scannedByteCount = 0

  package init(
    maximumLineBytes: Int = 1 * 1_024 * 1_024,
    maximumEventBytes: Int = 4 * 1_024 * 1_024
  ) {
    precondition(maximumLineBytes > 0)
    precondition(maximumEventBytes >= maximumLineBytes)
    self.maximumLineBytes = maximumLineBytes
    self.maximumEventBytes = maximumEventBytes
  }

  package mutating func feed(_ bytes: Data) throws -> [ServerSentEvent] {
    guard !bytes.isEmpty else { return [] }
    var events: [ServerSentEvent] = []
    for byte in bytes {
      scannedByteCount += 1
      try consumeStreamByte(byte, events: &events)
    }
    return events
  }

  package mutating func finish() throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    if checkingByteOrderMark, !streamPrefix.isEmpty {
      checkingByteOrderMark = false
      let prefix = streamPrefix
      streamPrefix.removeAll(keepingCapacity: false)
      for byte in prefix {
        try consumeContentByte(byte, events: &events)
      }
    }
    pendingLineFeedAfterCarriageReturn = false
    if !lineBytes.isEmpty {
      try processCurrentLine(events: &events)
    }
    if let event = dispatch() { events.append(event) }
    lineBytes.removeAll(keepingCapacity: false)
    streamPrefix.removeAll(keepingCapacity: false)
    return events
  }

  private mutating func consumeStreamByte(
    _ byte: UInt8,
    events: inout [ServerSentEvent]
  ) throws {
    guard checkingByteOrderMark else {
      try consumeContentByte(byte, events: &events)
      return
    }

    streamPrefix.append(byte)
    let expected = Self.utf8ByteOrderMark
    let prefix = Array(streamPrefix)
    if expected.starts(with: prefix) {
      if prefix.count == expected.count {
        streamPrefix.removeAll(keepingCapacity: false)
        checkingByteOrderMark = false
      }
      return
    }

    checkingByteOrderMark = false
    let buffered = streamPrefix
    streamPrefix.removeAll(keepingCapacity: false)
    for bufferedByte in buffered {
      try consumeContentByte(bufferedByte, events: &events)
    }
  }

  private mutating func consumeContentByte(
    _ byte: UInt8,
    events: inout [ServerSentEvent]
  ) throws {
    if pendingLineFeedAfterCarriageReturn {
      pendingLineFeedAfterCarriageReturn = false
      if byte == 0x0A { return }
    }

    switch byte {
    case 0x0D:
      try processCurrentLine(events: &events)
      pendingLineFeedAfterCarriageReturn = true
    case 0x0A:
      try processCurrentLine(events: &events)
    default:
      let (nextCount, overflowed) = lineBytes.count.addingReportingOverflow(1)
      guard !overflowed, nextCount <= maximumLineBytes else {
        throw ProviderFailure(code: .responseTooLarge, message: "SSE line exceeded its bound")
      }
      lineBytes.append(byte)
    }
  }

  private mutating func processCurrentLine(events: inout [ServerSentEvent]) throws {
    guard let line = String(data: lineBytes, encoding: .utf8) else {
      throw ProviderFailure(code: .malformedResponse, message: "SSE line is not valid UTF-8")
    }
    lineBytes.removeAll(keepingCapacity: true)
    try process(line: line, events: &events)
  }

  private mutating func process(line: String, events: inout [ServerSentEvent]) throws {
    if line.isEmpty {
      if let event = dispatch() { events.append(event) }
      return
    }
    if line.first == ":" { return }

    let field: Substring
    let value: Substring
    if let separator = line.firstIndex(of: ":") {
      field = line[..<separator]
      var start = line.index(after: separator)
      if start < line.endIndex, line[start] == " " { start = line.index(after: start) }
      value = line[start...]
    } else {
      field = line[...]
      value = ""
    }

    switch field {
    case "event":
      eventName = String(value)
    case "data":
      let value = String(value)
      let separatorBytes = dataLines.isEmpty ? 0 : 1
      let (withSeparator, firstOverflow) = dataByteCount.addingReportingOverflow(separatorBytes)
      let (next, secondOverflow) = withSeparator.addingReportingOverflow(value.utf8.count)
      guard !firstOverflow, !secondOverflow, next <= maximumEventBytes else {
        throw ProviderFailure(code: .responseTooLarge, message: "SSE event data exceeded its bound")
      }
      dataByteCount = next
      dataLines.append(value)
    case "id":
      if !value.contains("\u{0000}") { eventID = String(value) }
    case "retry":
      if value.allSatisfy(\.isNumber) { retryMilliseconds = UInt64(value) }
    default:
      break
    }
  }

  private mutating func dispatch() -> ServerSentEvent? {
    defer {
      eventName = nil
      dataLines.removeAll(keepingCapacity: true)
      dataByteCount = 0
      retryMilliseconds = nil
    }
    guard !dataLines.isEmpty else { return nil }
    return ServerSentEvent(
      event: eventName,
      data: dataLines.joined(separator: "\n"),
      id: eventID,
      retryMilliseconds: retryMilliseconds
    )
  }
}
