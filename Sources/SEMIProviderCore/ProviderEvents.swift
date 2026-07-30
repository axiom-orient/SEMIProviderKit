import Foundation

public struct ProviderResponseMetadata: Codable, Equatable, Sendable {
  public let requestID: ProviderRequestID
  public let providerRequestID: String?
  public let providerID: ProviderID
  public let modelID: ProviderModelID
  public let startedAt: Date

  public init(
    requestID: ProviderRequestID,
    providerRequestID: String?,
    providerID: ProviderID,
    modelID: ProviderModelID,
    startedAt: Date
  ) throws {
    try ProviderValueValidation.finiteDate(startedAt, field: "provider response start date")
    if let providerRequestID {
      guard !providerRequestID.isEmpty,
        providerRequestID.utf8.count <= 512,
        !providerRequestID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(
          code: .invalidValue,
          message: "provider request metadata is invalid"
        )
      }
    }
    self.requestID = requestID
    self.providerRequestID = providerRequestID
    self.providerID = providerID
    self.modelID = modelID
    self.startedAt = startedAt
  }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let cachedInputTokens: Int?
  public let totalTokens: Int?

  public init(
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedInputTokens: Int? = nil,
    totalTokens: Int? = nil
  ) throws {
    let values = [inputTokens, outputTokens, cachedInputTokens, totalTokens].compactMap { $0 }
    guard values.allSatisfy({ $0 >= 0 }) else {
      throw ProviderCoreError(code: .invalidValue, message: "provider usage is negative")
    }
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.totalTokens = totalTokens
  }
}

public struct ProviderCompletion: Codable, Equatable, Sendable {
  public let responseID: String?
  public let continuation: ProviderContinuation?
  public let usage: ProviderUsage?
  public let finishedAt: Date

  public init(
    responseID: String? = nil,
    continuation: ProviderContinuation? = nil,
    usage: ProviderUsage? = nil,
    finishedAt: Date
  ) throws {
    try ProviderValueValidation.finiteDate(finishedAt, field: "provider completion date")
    if let responseID {
      guard !responseID.isEmpty,
        responseID.utf8.count <= 512,
        !responseID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(code: .invalidValue, message: "provider response ID is invalid")
      }
    }
    self.responseID = responseID
    self.continuation = continuation
    self.usage = usage
    self.finishedAt = finishedAt
  }
}

public enum ProviderFailureCode: String, Codable, CaseIterable, Sendable {
  case invalidRequest = "invalid_request"
  case providerUnsupported = "provider_unsupported"
  case accountUnavailable = "account_unavailable"
  case authenticationFailed = "authentication_failed"
  case permissionDenied = "permission_denied"
  case modelUnavailable = "model_unavailable"
  case capabilityMismatch = "capability_mismatch"
  case rateLimited = "rate_limited"
  case billingUnavailable = "billing_unavailable"
  case transportFailed = "transport_failed"
  case responseTooLarge = "response_too_large"
  case malformedResponse = "malformed_response"
  case consumerBackpressureExceeded = "consumer_backpressure_exceeded"
  case timedOut = "timed_out"
  case cancelled = "cancelled"
  case serverFailed = "server_failed"
  case credentialRecoveryRequired = "credential_recovery_required"
  case internalInvariant = "internal_invariant"
}

public struct ProviderFailure: Error, Codable, Equatable, Sendable {
  public let code: ProviderFailureCode
  public let message: String
  public let providerStatusCode: Int?
  public let retryAfterMilliseconds: UInt64?
  public let requestID: ProviderRequestID?

  public init(
    code: ProviderFailureCode,
    message: String,
    providerStatusCode: Int? = nil,
    retryAfterMilliseconds: UInt64? = nil,
    requestID: ProviderRequestID? = nil
  ) {
    let clean = Self.redacted(message)
    self.code = code
    self.message = clean.isEmpty ? code.rawValue : String(clean.prefix(1_024))
    self.providerStatusCode = providerStatusCode
    self.retryAfterMilliseconds = retryAfterMilliseconds
    self.requestID = requestID
  }

  private static func redacted(_ input: String) -> String {
    var output = input.replacingOccurrences(
      of: #"(?i)bearer\s+[a-z0-9._~+/=-]+"#,
      with: "Bearer <redacted>",
      options: .regularExpression
    )
    output = output.replacingOccurrences(
      of: #"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token)\s*[:=]\s*[^\s,;]+"#,
      with: "$1=<redacted>",
      options: .regularExpression
    )
    return output
  }
}

public enum ProviderTerminal: Codable, Equatable, Sendable {
  case completed(ProviderCompletion)
  case cancelled
  case failed(ProviderFailure)
}

public enum ProviderTurnEvent: Codable, Equatable, Sendable {
  case started(ProviderResponseMetadata)
  case textDelta(String)
  case toolCall(ProviderToolCall)
  case terminal(ProviderTerminal)
}
