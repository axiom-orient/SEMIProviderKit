import Foundation

package enum ProviderValueValidation {
  package static func accountLabel(_ value: String) throws {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.utf8.count <= 128,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "provider account label is invalid")
    }
  }

  package static func finiteDate(_ value: Date, field: String) throws {
    guard value.timeIntervalSinceReferenceDate.isFinite else {
      throw ProviderCoreError(code: .invalidValue, message: "\(field) is invalid")
    }
  }

  package static func optionalFiniteDate(_ value: Date?, field: String) throws {
    if let value { try finiteDate(value, field: field) }
  }

  package static func credentialRecord(_ record: ProviderCredentialRecord) throws {
    try accountLabel(record.label)
    try finiteDate(record.createdAt, field: "credential creation date")
    try finiteDate(record.updatedAt, field: "credential update date")
    guard record.updatedAt >= record.createdAt else {
      throw ProviderCoreError(
        code: .invalidValue,
        message: "credential update date precedes its creation date"
      )
    }
  }

  package static func credentialRecords(_ records: [ProviderCredentialRecord]) throws {
    var accounts = Set<ProviderAccountID>()
    var references = Set<ProviderCredentialReference>()
    for record in records {
      try credentialRecord(record)
      guard accounts.insert(record.accountID).inserted else {
        throw ProviderCoreError(
          code: .invalidValue,
          message: "credential vault contains duplicate account records"
        )
      }
      guard references.insert(record.reference).inserted else {
        throw ProviderCoreError(
          code: .invalidValue,
          message: "credential vault contains duplicate references"
        )
      }
    }
  }

  package static func credentialLease(
    _ lease: ProviderCredentialLease,
    requiresActiveRecord: Bool
  ) throws {
    try credentialRecord(lease.record)
    guard lease.record.source == lease.material.source else {
      throw ProviderCoreError(
        code: .invalidValue,
        message: "credential material source does not match its record"
      )
    }
    if requiresActiveRecord, lease.record.state != .active {
      throw ProviderCoreError(code: .invalidValue, message: "credential record is not active")
    }
  }

  package static func optionalHTTPStatusCode(_ value: Int?) throws {
    if let value, !(100...599).contains(value) {
      throw ProviderCoreError(code: .invalidValue, message: "provider HTTP status code is invalid")
    }
  }
}

extension ProviderEndpointConfiguration {
  enum CodingKeys: String, CodingKey { case baseURL }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(baseURL: container.decode(URL.self, forKey: .baseURL))
  }
}

extension ProviderCredentialRecord {
  enum CodingKeys: String, CodingKey {
    case reference
    case accountID
    case providerID
    case label
    case source
    case state
    case endpoint
    case createdAt
    case updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = Self(
      reference: try container.decode(ProviderCredentialReference.self, forKey: .reference),
      accountID: try container.decode(ProviderAccountID.self, forKey: .accountID),
      providerID: try container.decode(ProviderID.self, forKey: .providerID),
      label: try container.decode(String.self, forKey: .label),
      source: try container.decode(ProviderCredentialSource.self, forKey: .source),
      state: try container.decode(ProviderCredentialRecordState.self, forKey: .state),
      endpoint: try container.decodeIfPresent(
        ProviderEndpointConfiguration.self,
        forKey: .endpoint
      ),
      createdAt: try container.decode(Date.self, forKey: .createdAt),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt)
    )
    try ProviderValueValidation.credentialRecord(value)
    self = value
  }
}

extension ProviderAccountInspection {
  enum CodingKeys: String, CodingKey {
    case accountID
    case providerID
    case readiness
    case message
    case capabilities
    case inspectedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let inspectedAt = try container.decode(Date.self, forKey: .inspectedAt)
    try ProviderValueValidation.finiteDate(inspectedAt, field: "account inspection date")
    try self.init(
      accountID: container.decode(ProviderAccountID.self, forKey: .accountID),
      providerID: container.decode(ProviderID.self, forKey: .providerID),
      readiness: container.decode(ProviderAccountReadiness.self, forKey: .readiness),
      message: container.decodeIfPresent(String.self, forKey: .message),
      capabilities: container.decode(ProviderCapabilities.self, forKey: .capabilities),
      inspectedAt: inspectedAt
    )
  }
}

extension ProviderAccountSummary {
  enum CodingKeys: String, CodingKey {
    case accountID
    case providerID
    case label
    case credentialSource
    case readiness
    case endpoint
    case lastInspectedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let label = try container.decode(String.self, forKey: .label)
    let lastInspectedAt = try container.decodeIfPresent(Date.self, forKey: .lastInspectedAt)
    try ProviderValueValidation.accountLabel(label)
    try ProviderValueValidation.optionalFiniteDate(
      lastInspectedAt,
      field: "last account inspection date"
    )
    self.init(
      accountID: try container.decode(ProviderAccountID.self, forKey: .accountID),
      providerID: try container.decode(ProviderID.self, forKey: .providerID),
      label: label,
      credentialSource: try container.decode(
        ProviderCredentialSource.self,
        forKey: .credentialSource
      ),
      readiness: try container.decode(ProviderAccountReadiness.self, forKey: .readiness),
      endpoint: try container.decodeIfPresent(
        ProviderEndpointConfiguration.self,
        forKey: .endpoint
      ),
      lastInspectedAt: lastInspectedAt
    )
  }
}

extension ProviderCredentialReconciliationReport {
  enum CodingKeys: String, CodingKey {
    case activeRecordCount
    case removedStagedReferences
    case issues
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      activeRecordCount: container.decode(Int.self, forKey: .activeRecordCount),
      removedStagedReferences: container.decode(
        [ProviderCredentialReference].self,
        forKey: .removedStagedReferences
      ),
      issues: container.decode([ProviderCredentialReconciliationIssue].self, forKey: .issues)
    )
  }
}

extension ProviderDescriptor {
  enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case protocolFamily
    case supportsAPIKey
    case supportsOAuth
    case requiresExplicitEndpoint
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ProviderID.self, forKey: .id),
      displayName: container.decode(String.self, forKey: .displayName),
      protocolFamily: container.decode(ProviderProtocolFamily.self, forKey: .protocolFamily),
      supportsAPIKey: container.decode(Bool.self, forKey: .supportsAPIKey),
      supportsOAuth: container.decode(Bool.self, forKey: .supportsOAuth),
      requiresExplicitEndpoint: container.decode(Bool.self, forKey: .requiresExplicitEndpoint)
    )
  }
}

extension ProviderMessage {
  enum CodingKeys: String, CodingKey { case role, content }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      role: container.decode(ProviderMessageRole.self, forKey: .role),
      content: container.decode([ProviderMessageContent].self, forKey: .content)
    )
  }
}

extension ProviderToolDefinition {
  enum CodingKeys: String, CodingKey { case name, description, inputSchema, strict }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: container.decode(String.self, forKey: .name),
      description: container.decode(String.self, forKey: .description),
      inputSchema: container.decode(ProviderJSONValue.self, forKey: .inputSchema),
      strict: container.decode(Bool.self, forKey: .strict)
    )
  }
}

extension ProviderToolCall {
  enum CodingKeys: String, CodingKey { case id, name, arguments }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      name: container.decode(String.self, forKey: .name),
      arguments: container.decode(ProviderJSONValue.self, forKey: .arguments)
    )
  }
}

extension ProviderContinuation {
  enum CodingKeys: String, CodingKey { case providerID, accountID, value }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      providerID: container.decode(ProviderID.self, forKey: .providerID),
      accountID: container.decode(ProviderAccountID.self, forKey: .accountID),
      value: container.decode(String.self, forKey: .value)
    )
  }
}

extension ProviderRequestConstraints {
  enum CodingKeys: String, CodingKey {
    case dataCollection
    case requiresZeroDataRetention
    case requiresParameterSupport
    case allowsProviderEndpointFallbacks
    case timeoutMilliseconds
    case maximumResponseBytes
    case maximumRetryAttempts
    case maximumOutputTokens
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      dataCollection: container.decode(ProviderDataCollectionPolicy.self, forKey: .dataCollection),
      requiresZeroDataRetention: container.decode(
        Bool.self,
        forKey: .requiresZeroDataRetention
      ),
      requiresParameterSupport: container.decode(Bool.self, forKey: .requiresParameterSupport),
      allowsProviderEndpointFallbacks: container.decode(
        Bool.self,
        forKey: .allowsProviderEndpointFallbacks
      ),
      timeoutMilliseconds: container.decode(UInt64.self, forKey: .timeoutMilliseconds),
      maximumResponseBytes: container.decode(Int.self, forKey: .maximumResponseBytes),
      maximumRetryAttempts: container.decode(Int.self, forKey: .maximumRetryAttempts),
      maximumOutputTokens: container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens)
    )
  }
}

extension ProviderTurnRequest {
  enum CodingKeys: String, CodingKey {
    case id
    case selection
    case messages
    case tools
    case toolChoice
    case output
    case reasoning
    case continuation
    case constraints
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ProviderRequestID.self, forKey: .id),
      selection: container.decode(ProviderSelection.self, forKey: .selection),
      messages: container.decode([ProviderMessage].self, forKey: .messages),
      tools: container.decode([ProviderToolDefinition].self, forKey: .tools),
      toolChoice: container.decode(ProviderToolChoice.self, forKey: .toolChoice),
      output: container.decode(ProviderOutputRequirement.self, forKey: .output),
      reasoning: container.decode(ProviderReasoningPolicy.self, forKey: .reasoning),
      continuation: container.decodeIfPresent(ProviderContinuation.self, forKey: .continuation),
      constraints: container.decode(ProviderRequestConstraints.self, forKey: .constraints)
    )
  }
}

extension ProviderModelDescriptor {
  enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case capabilities
    case contextTokenLimit
    case maximumOutputTokens
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ProviderModelID.self, forKey: .id),
      displayName: container.decodeIfPresent(String.self, forKey: .displayName),
      capabilities: container.decode(ProviderCapabilities.self, forKey: .capabilities),
      contextTokenLimit: container.decodeIfPresent(Int.self, forKey: .contextTokenLimit),
      maximumOutputTokens: container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens)
    )
  }
}

extension ProviderModelCatalogResult {
  enum CodingKeys: String, CodingKey { case models, refreshedAt }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
    try ProviderValueValidation.finiteDate(refreshedAt, field: "model catalog refresh date")
    try self.init(
      models: container.decode([ProviderModelDescriptor].self, forKey: .models),
      refreshedAt: refreshedAt
    )
  }
}

extension ProviderResponseMetadata {
  enum CodingKeys: String, CodingKey {
    case requestID
    case providerRequestID
    case providerID
    case modelID
    case startedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let startedAt = try container.decode(Date.self, forKey: .startedAt)
    try ProviderValueValidation.finiteDate(startedAt, field: "provider response start date")
    try self.init(
      requestID: container.decode(ProviderRequestID.self, forKey: .requestID),
      providerRequestID: container.decodeIfPresent(String.self, forKey: .providerRequestID),
      providerID: container.decode(ProviderID.self, forKey: .providerID),
      modelID: container.decode(ProviderModelID.self, forKey: .modelID),
      startedAt: startedAt
    )
  }
}

extension ProviderUsage {
  enum CodingKeys: String, CodingKey {
    case inputTokens
    case outputTokens
    case cachedInputTokens
    case totalTokens
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      inputTokens: container.decodeIfPresent(Int.self, forKey: .inputTokens),
      outputTokens: container.decodeIfPresent(Int.self, forKey: .outputTokens),
      cachedInputTokens: container.decodeIfPresent(Int.self, forKey: .cachedInputTokens),
      totalTokens: container.decodeIfPresent(Int.self, forKey: .totalTokens)
    )
  }
}

extension ProviderCompletion {
  enum CodingKeys: String, CodingKey {
    case responseID
    case continuation
    case usage
    case finishedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let finishedAt = try container.decode(Date.self, forKey: .finishedAt)
    try ProviderValueValidation.finiteDate(finishedAt, field: "provider completion date")
    try self.init(
      responseID: container.decodeIfPresent(String.self, forKey: .responseID),
      continuation: container.decodeIfPresent(ProviderContinuation.self, forKey: .continuation),
      usage: container.decodeIfPresent(ProviderUsage.self, forKey: .usage),
      finishedAt: finishedAt
    )
  }
}

extension ProviderFailure {
  enum CodingKeys: String, CodingKey {
    case code
    case message
    case providerStatusCode
    case retryAfterMilliseconds
    case requestID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let providerStatusCode = try container.decodeIfPresent(Int.self, forKey: .providerStatusCode)
    try ProviderValueValidation.optionalHTTPStatusCode(providerStatusCode)
    self.init(
      code: try container.decode(ProviderFailureCode.self, forKey: .code),
      message: try container.decode(String.self, forKey: .message),
      providerStatusCode: providerStatusCode,
      retryAfterMilliseconds: try container.decodeIfPresent(
        UInt64.self,
        forKey: .retryAfterMilliseconds
      ),
      requestID: try container.decodeIfPresent(ProviderRequestID.self, forKey: .requestID)
    )
  }
}
