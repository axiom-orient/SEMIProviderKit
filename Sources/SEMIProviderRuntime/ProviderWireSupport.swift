import Foundation
import SEMIProviderCore

extension ProviderJSONValue {
  package subscript(key: String) -> ProviderJSONValue? { objectValue?[key] }

  package var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  package var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  package var integerValue: Int? {
    guard let value = numberValue,
      value.isFinite,
      value.rounded(.towardZero) == value
    else { return nil }
    return Int(exactly: value)
  }

  package func value(at path: String...) -> ProviderJSONValue? {
    path.reduce(Optional(self)) { value, key in value?[key] }
  }
}

package struct ProviderCompletionDraft: Equatable, Sendable {
  package let responseID: String?
  package let continuation: ProviderContinuation?
  package let usage: ProviderUsage?

  package init(
    responseID: String? = nil,
    continuation: ProviderContinuation? = nil,
    usage: ProviderUsage? = nil
  ) {
    self.responseID = responseID
    self.continuation = continuation
    self.usage = usage
  }

  package func materialize(at date: Date) throws -> ProviderCompletion {
    try ProviderCompletion(
      responseID: responseID,
      continuation: continuation,
      usage: usage,
      finishedAt: date
    )
  }
}

package struct ProviderToolArgumentAccumulator: Sendable {
  private let maximumBytes: Int
  private var bytes = Data()

  package init(maximumBytes: Int = ProviderJSONValue.maximumEncodedBytes) {
    precondition(maximumBytes > 0)
    self.maximumBytes = maximumBytes
  }

  package var byteCount: Int { bytes.count }

  package mutating func append(_ fragment: String) throws {
    try append(Data(fragment.utf8), replacing: false)
  }

  package mutating func replace(with value: String) throws {
    try append(Data(value.utf8), replacing: true)
  }

  package func decodeObject() throws -> ProviderJSONValue {
    let value = try ProviderWireValidation.decodeJSON(bytes, field: "tool arguments")
    guard value.objectValue != nil else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider tool arguments must decode to a JSON object"
      )
    }
    return value
  }

  private mutating func append(_ fragment: Data, replacing: Bool) throws {
    let existingCount = replacing ? 0 : bytes.count
    let (nextCount, overflowed) = existingCount.addingReportingOverflow(fragment.count)
    guard !overflowed, nextCount <= maximumBytes else {
      throw ProviderFailure(
        code: .responseTooLarge,
        message: "provider tool arguments exceeded their byte limit"
      )
    }
    if replacing { bytes.removeAll(keepingCapacity: true) }
    bytes.append(fragment)
  }
}

package enum ProviderDecodedEvent: Equatable, Sendable {
  case textDelta(String)
  case toolCall(ProviderToolCall)
  case completed(ProviderCompletionDraft)
}

package protocol ProviderStreamDecoder: AnyObject {
  func consume(_ event: ServerSentEvent) throws -> [ProviderDecodedEvent]
  func finish() throws -> [ProviderDecodedEvent]
}

package protocol ProviderAdapter: Sendable {
  var descriptor: ProviderDescriptor { get }
  /// Async because a credential source may need bounded off-actor work (for
  /// example resolving an externally managed client version) before the wire
  /// request exists. Blocking that resolution on the execution actor would stop
  /// the deadline watcher and cancellation from ever running.
  func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest
  func makeDecoder(for request: ProviderTurnRequest) throws -> any ProviderStreamDecoder
  func inspect(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderAccountInspection
  func models(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderModelCatalogResult
}

package enum ProviderWireError {
  package static func failure(
    _ error: any Error,
    requestID: ProviderRequestID? = nil
  ) -> ProviderFailure {
    if let failure = error as? ProviderFailure {
      if failure.requestID != nil || requestID == nil { return failure }
      return .init(
        code: failure.code,
        message: failure.message,
        providerStatusCode: failure.providerStatusCode,
        retryAfterMilliseconds: failure.retryAfterMilliseconds,
        requestID: requestID
      )
    }
    if error is CancellationError {
      return .init(code: .cancelled, message: "provider request cancelled", requestID: requestID)
    }
    if let urlError = error as? URLError {
      return urlFailure(urlError.code, requestID: requestID)
    }
    if let coreError = error as? ProviderCoreError {
      let code: ProviderFailureCode
      switch coreError.code {
      case .invalidIdentifier, .invalidValue, .invalidRequest:
        code = .invalidRequest
      case .invalidTransition, .generationExhausted:
        code = .internalInvariant
      }
      return .init(
        code: code,
        message: "provider value processing failed",
        requestID: requestID
      )
    }
    switch error as? ProviderTransportError {
    case .responseTooLarge:
      return .init(
        code: .responseTooLarge, message: "provider response exceeded its byte limit",
        requestID: requestID)
    case .consumerBackpressureExceeded:
      return .init(
        code: .consumerBackpressureExceeded,
        message: "provider transport consumer exceeded its backlog", requestID: requestID)
    case .invalidResponse:
      return .init(
        code: .malformedResponse, message: "provider returned an invalid HTTP response",
        requestID: requestID)
    case .transport(let message):
      return .init(code: .transportFailed, message: message, requestID: requestID)
    case nil:
      return .init(
        code: .transportFailed,
        message: "provider operation failed unexpectedly",
        requestID: requestID
      )
    }
  }

  private static func urlFailure(
    _ code: URLError.Code,
    requestID: ProviderRequestID?
  ) -> ProviderFailure {
    switch code {
    case .cancelled:
      return .init(
        code: .cancelled,
        message: "provider request cancelled",
        requestID: requestID
      )
    case .timedOut:
      return .init(
        code: .timedOut,
        message: "provider network request timed out",
        requestID: requestID
      )
    case .notConnectedToInternet:
      return .init(
        code: .transportFailed,
        message: "provider network is unavailable",
        requestID: requestID
      )
    case .cannotFindHost, .dnsLookupFailed:
      return .init(
        code: .transportFailed,
        message: "provider host could not be resolved",
        requestID: requestID
      )
    case .cannotConnectToHost, .networkConnectionLost:
      return .init(
        code: .transportFailed,
        message: "provider connection failed",
        requestID: requestID
      )
    case .secureConnectionFailed, .serverCertificateHasBadDate,
      .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid, .clientCertificateRejected,
      .clientCertificateRequired:
      return .init(
        code: .transportFailed,
        message: "provider secure connection failed",
        requestID: requestID
      )
    default:
      return .init(
        code: .transportFailed,
        message: "provider network request failed",
        requestID: requestID
      )
    }
  }

  package static func httpFailure(
    statusCode: Int,
    headers: [String: String],
    body: Data,
    requestID: ProviderRequestID? = nil,
    now: Date
  ) -> ProviderFailure {
    let message =
      providerErrorMessage(body) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
    let code: ProviderFailureCode
    switch statusCode {
    case 400, 409, 422: code = .invalidRequest
    case 401: code = .authenticationFailed
    case 403: code = .permissionDenied
    case 404: code = .modelUnavailable
    case 402: code = .billingUnavailable
    case 408, 504: code = .timedOut
    case 429: code = .rateLimited
    case 500...599: code = .serverFailed
    default: code = .transportFailed
    }
    return .init(
      code: code,
      message: message,
      providerStatusCode: statusCode,
      retryAfterMilliseconds: retryAfterMilliseconds(headers: headers, now: now),
      requestID: requestID
    )
  }

  private static func providerErrorMessage(_ data: Data) -> String? {
    guard !data.isEmpty, data.count <= ProviderJSONValue.maximumEncodedBytes,
      let root = try? ProviderJSONValue.decode(from: data)
    else { return nil }
    return root.value(at: "error", "message")?.stringValue
      ?? root["message"]?.stringValue
      ?? root.value(at: "error", "type")?.stringValue
      ?? root["error"]?.stringValue
  }

  private static func retryAfterMilliseconds(
    headers: [String: String],
    now: Date
  ) -> UInt64? {
    guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }
    if let seconds = UInt64(raw) {
      let (milliseconds, overflowed) = seconds.multipliedReportingOverflow(by: 1_000)
      return overflowed ? nil : milliseconds
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: raw) else { return nil }
    let seconds = max(0, date.timeIntervalSince(now))
    guard seconds <= Double(UInt64.max / 1_000) else { return nil }
    return UInt64(seconds * 1_000)
  }
}

package enum ProviderWireValidation {
  package static func decodeJSON(
    _ data: Data,
    field: String
  ) throws -> ProviderJSONValue {
    do {
      return try ProviderJSONValue.decode(from: data)
    } catch let failure as ProviderFailure {
      throw failure
    } catch {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider returned invalid \(field)"
      )
    }
  }

  package static func optionalNonnegativeInteger(
    _ value: ProviderJSONValue?,
    field: String
  ) throws -> Int? {
    guard let value else { return nil }
    if case .null = value { return nil }
    guard let integer = value.integerValue, integer >= 0 else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider returned an invalid \(field)"
      )
    }
    return integer
  }

  package static func nonnegativeInteger(
    _ value: ProviderJSONValue?,
    defaultValue: Int,
    field: String
  ) throws -> Int {
    guard let value else { return defaultValue }
    guard let integer = value.integerValue, integer >= 0 else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider returned an invalid \(field)"
      )
    }
    return integer
  }

  package static func object(
    _ value: ProviderJSONValue,
    field: String
  ) throws -> [String: ProviderJSONValue] {
    guard let object = value.objectValue else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider returned a non-object \(field)"
      )
    }
    return object
  }

  package static func array(
    _ value: ProviderJSONValue,
    field: String
  ) throws -> [ProviderJSONValue] {
    guard let array = value.arrayValue else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider returned a non-array \(field)"
      )
    }
    return array
  }

  package static func requireAPIKey(_ lease: ProviderCredentialLease) throws -> String {
    switch lease.material {
    case .apiKey(let value), .oauthDerivedKey(let value):
      return value.revealed
    case .externalAuthFile:
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "this provider requires an API key credential"
      )
    }
  }

  /// Returns whether the caller explicitly opted into provider-side response storage.
  package static func storesServerSideResponse(_ request: ProviderTurnRequest) -> Bool {
    request.constraints.dataCollection == .allow
      && !request.constraints.requiresZeroDataRetention
  }

  /// Provider continuations use server-side state. They must never turn the
  /// request's default no-retention policy into an implicit storage decision.
  package static func requireServerSideContinuationOptIn(
    _ request: ProviderTurnRequest
  ) throws {
    guard request.continuation != nil else { return }
    guard storesServerSideResponse(request)
    else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message:
          "provider continuation requires explicit server-side retention and data-collection opt-in"
      )
    }
  }

  package static func appendPath(_ path: String, to base: URL) throws -> URL {
    guard path.hasPrefix("/") else {
      throw ProviderFailure(code: .internalInvariant, message: "provider endpoint path is invalid")
    }
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    let basePath = components?.percentEncodedPath ?? ""
    let normalizedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
    components?.percentEncodedPath = normalizedBase + path
    guard let url = components?.url else {
      throw ProviderFailure(code: .invalidRequest, message: "provider endpoint URL is invalid")
    }
    return url
  }

  package static func makeJSONRequest(
    url: URL,
    method: String = "POST",
    headers: [String: String],
    body: ProviderJSONValue?,
    constraints: ProviderRequestConstraints
  ) throws -> ProviderHTTPRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = Double(constraints.timeoutMilliseconds) / 1_000
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers {
      guard !name.isEmpty, !value.isEmpty,
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !value.unicodeScalars.contains(where: { scalar in
          scalar.value == 0 || scalar.value == 10 || scalar.value == 13
        })
      else {
        throw ProviderFailure(code: .invalidRequest, message: "provider HTTP header is invalid")
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let body { request.httpBody = try body.encodedData() }
    return ProviderHTTPRequest(
      urlRequest: request,
      maximumResponseBytes: constraints.maximumResponseBytes
    )
  }

  package static func parseModelCatalog(
    data: Data,
    candidateArrays: [[String]],
    idKeys: [String],
    capabilities: ProviderCapabilities,
    refreshedAt: Date
  ) throws -> ProviderModelCatalogResult {
    let root = try decodeJSON(data, field: "model catalog JSON")
    var array: [ProviderJSONValue]?
    for path in candidateArrays {
      var value: ProviderJSONValue? = root
      for key in path { value = value?[key] }
      if let candidate = value?.arrayValue {
        array = candidate
        break
      }
    }
    guard let array else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "provider model catalog is missing its model array"
      )
    }

    var models: [ProviderModelDescriptor] = []
    models.reserveCapacity(array.count)
    var seen = Set<ProviderModelID>()
    for (index, entry) in array.enumerated() {
      guard let object = entry.objectValue else {
        throw malformedCatalog("model entry \(index) is not an object")
      }

      var rawID: String?
      for key in idKeys {
        guard let candidate = object[key] else { continue }
        guard let value = candidate.stringValue else {
          throw malformedCatalog("model entry \(index) has a non-string \(key)")
        }
        rawID = value
        break
      }
      guard let rawID, let id = ProviderModelID(rawValue: rawID) else {
        throw malformedCatalog("model entry \(index) has no valid identifier")
      }
      guard seen.insert(id).inserted else {
        throw malformedCatalog("model catalog contains duplicate identifier \(rawID)")
      }

      let displayName = try optionalString(
        object,
        keys: ["display_name", "displayName", "name"],
        entryIndex: index
      )
      let limit = try optionalPositiveInteger(
        object,
        keys: ["context_length", "inputTokenLimit"],
        entryIndex: index
      )
      let directOutputLimit = try optionalPositiveInteger(
        object,
        keys: ["max_tokens", "max_completion_tokens", "outputTokenLimit"],
        entryIndex: index
      )
      let nestedOutputLimit: Int?
      if let topProvider = object["top_provider"] {
        let topProviderObject = try Self.object(topProvider, field: "model top provider")
        nestedOutputLimit = try optionalPositiveInteger(
          topProviderObject,
          keys: ["max_completion_tokens"],
          entryIndex: index
        )
      } else {
        nestedOutputLimit = nil
      }
      models.append(
        try ProviderModelDescriptor(
          id: id,
          displayName: displayName == rawID ? nil : displayName,
          capabilities: capabilities,
          contextTokenLimit: limit,
          maximumOutputTokens: directOutputLimit ?? nestedOutputLimit
        )
      )
    }
    return try ProviderModelCatalogResult(models: models, refreshedAt: refreshedAt)
  }

  private static func optionalString(
    _ object: [String: ProviderJSONValue],
    keys: [String],
    entryIndex: Int
  ) throws -> String? {
    for key in keys {
      guard let value = object[key] else { continue }
      if case .null = value { return nil }
      guard let string = value.stringValue else {
        throw malformedCatalog("model entry \(entryIndex) has a non-string \(key)")
      }
      return string
    }
    return nil
  }

  private static func optionalPositiveInteger(
    _ object: [String: ProviderJSONValue],
    keys: [String],
    entryIndex: Int
  ) throws -> Int? {
    for key in keys {
      guard let value = object[key] else { continue }
      if case .null = value { return nil }
      guard let integer = value.integerValue, integer > 0 else {
        throw malformedCatalog("model entry \(entryIndex) has an invalid \(key)")
      }
      return integer
    }
    return nil
  }

  private static func malformedCatalog(_ message: String) -> ProviderFailure {
    ProviderFailure(code: .malformedResponse, message: message)
  }
}
