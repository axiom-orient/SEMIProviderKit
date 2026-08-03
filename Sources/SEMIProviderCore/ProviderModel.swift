import Foundation

public enum ProviderProtocolFamily: String, Codable, CaseIterable, Sendable {
  case codexResponses = "codex_responses"
  case openAIResponses = "openai_responses"
  case anthropicMessages = "anthropic_messages"
  case geminiInteractions = "gemini_interactions"
  case openAIChatCompletions = "openai_chat_completions"
}

public struct ProviderDescriptor: Codable, Equatable, Sendable {
  public let id: ProviderID
  public let displayName: String
  public let protocolFamily: ProviderProtocolFamily
  public let supportsAPIKey: Bool
  public let supportsOAuth: Bool
  public let requiresExplicitEndpoint: Bool

  public init(
    id: ProviderID,
    displayName: String,
    protocolFamily: ProviderProtocolFamily,
    supportsAPIKey: Bool,
    supportsOAuth: Bool,
    requiresExplicitEndpoint: Bool = false
  ) throws {
    let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized == displayName,
      !displayName.isEmpty,
      displayName.utf8.count <= 128,
      !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "provider display name is invalid")
    }
    self.id = id
    self.displayName = displayName
    self.protocolFamily = protocolFamily
    self.supportsAPIKey = supportsAPIKey
    self.supportsOAuth = supportsOAuth
    self.requiresExplicitEndpoint = requiresExplicitEndpoint
  }
}

public struct ProviderSelection: Codable, Equatable, Hashable, Sendable {
  public let providerID: ProviderID
  public let accountID: ProviderAccountID
  public let modelID: ProviderModelID

  public init(
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ProviderModelID
  ) {
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
  }
}

public enum ProviderMessageRole: String, Codable, CaseIterable, Sendable {
  case system
  case developer
  case user
  case assistant
  case tool
}

public enum ProviderMessageContent: Codable, Equatable, Sendable {
  case text(String)
  /// A client-side tool call previously emitted by the assistant.
  ///
  /// Callers append this to caller-owned history before appending the matching
  /// `toolResult`, so stateless provider requests preserve the tool round trip.
  case toolCall(callID: String, name: String, arguments: ProviderJSONValue)
  case toolResult(callID: String, name: String, value: ProviderJSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case callID = "call_id"
    case name
    case value
  }

  private enum Kind: String, Codable {
    case text
    case toolCall = "tool_call"
    case toolResult = "tool_result"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .text:
      self = .text(try container.decode(String.self, forKey: .text))
    case .toolCall:
      self = .toolCall(
        callID: try container.decode(String.self, forKey: .callID),
        name: try container.decode(String.self, forKey: .name),
        arguments: try container.decode(ProviderJSONValue.self, forKey: .value)
      )
    case .toolResult:
      self = .toolResult(
        callID: try container.decode(String.self, forKey: .callID),
        name: try container.decode(String.self, forKey: .name),
        value: try container.decode(ProviderJSONValue.self, forKey: .value)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode(Kind.text, forKey: .type)
      try container.encode(text, forKey: .text)
    case .toolCall(let callID, let name, let arguments):
      try container.encode(Kind.toolCall, forKey: .type)
      try container.encode(callID, forKey: .callID)
      try container.encode(name, forKey: .name)
      try container.encode(arguments, forKey: .value)
    case .toolResult(let callID, let name, let value):
      try container.encode(Kind.toolResult, forKey: .type)
      try container.encode(callID, forKey: .callID)
      try container.encode(name, forKey: .name)
      try container.encode(value, forKey: .value)
    }
  }
}

public struct ProviderMessage: Codable, Equatable, Sendable {
  public static let maximumContentItems = 64
  public static let maximumTextScalars = 262_144

  public let role: ProviderMessageRole
  public let content: [ProviderMessageContent]

  public init(role: ProviderMessageRole, text: String) throws {
    try self.init(role: role, content: [.text(text)])
  }

  public init(role: ProviderMessageRole, content: [ProviderMessageContent]) throws {
    guard !content.isEmpty, content.count <= Self.maximumContentItems else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider message content is empty")
    }
    var textScalars = 0
    for item in content {
      switch item {
      case .text(let text):
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
          throw ProviderCoreError(
            code: .invalidRequest,
            message: "provider message text is empty or contains NUL"
          )
        }
        let (next, overflowed) = textScalars.addingReportingOverflow(text.unicodeScalars.count)
        guard !overflowed, next <= Self.maximumTextScalars else {
          throw ProviderCoreError(code: .invalidRequest, message: "provider message is oversized")
        }
        textScalars = next
      case .toolCall(let callID, let name, let arguments):
        try Self.validateToolCallID(callID)
        try Self.validateToolName(name)
        guard arguments.objectValue != nil else {
          throw ProviderCoreError(
            code: .invalidRequest,
            message: "provider tool call arguments must be an object"
          )
        }
        _ = try arguments.validated()
        guard role == .assistant else {
          throw ProviderCoreError(
            code: .invalidRequest,
            message: "tool call content requires the assistant message role"
          )
        }
      case .toolResult(let callID, let name, let value):
        try Self.validateToolCallID(callID)
        try Self.validateToolName(name)
        _ = try value.validated()
        guard role == .tool else {
          throw ProviderCoreError(
            code: .invalidRequest,
            message: "tool result content requires the tool message role"
          )
        }
      }
    }
    if role == .tool,
      !content.allSatisfy({ item in
        if case .toolResult = item { return true }
        return false
      })
    {
      throw ProviderCoreError(
        code: .invalidRequest,
        message: "tool messages may contain only tool results"
      )
    }
    self.role = role
    self.content = content
  }

  package static func validateToolCallID(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= 192,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider tool call ID is invalid")
    }
  }

  package static func validateToolName(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= 128,
      value.utf8.allSatisfy({ byte in
        switch byte {
        case 45, 46, 48...57, 95, 65...90, 97...122: true
        default: false
        }
      })
    else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider tool name is invalid")
    }
  }
}

public struct ProviderToolDefinition: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let inputSchema: ProviderJSONValue
  public let strict: Bool

  public init(
    name: String,
    description: String,
    inputSchema: ProviderJSONValue,
    strict: Bool = true
  ) throws {
    try ProviderMessage.validateToolName(name)
    guard !description.isEmpty,
      description.utf8.count <= 8_192,
      !description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      inputSchema.objectValue != nil
    else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider tool definition is invalid")
    }
    _ = try inputSchema.validated()
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.strict = strict
  }
}

public struct ProviderToolCall: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let arguments: ProviderJSONValue

  public init(id: String, name: String, arguments: ProviderJSONValue) throws {
    try ProviderMessage.validateToolCallID(id)
    try ProviderMessage.validateToolName(name)
    guard arguments.objectValue != nil else {
      throw ProviderCoreError(
        code: .invalidValue, message: "provider tool arguments must be an object")
    }
    _ = try arguments.validated()
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public enum ProviderToolChoice: Codable, Equatable, Sendable {
  case automatic
  case required
  case named(String)

  private enum CodingKeys: String, CodingKey {
    case type
    case name
  }

  private enum Kind: String, Codable {
    case automatic
    case required
    case named
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .automatic:
      self = .automatic
    case .required:
      self = .required
    case .named:
      let name = try container.decode(String.self, forKey: .name)
      try ProviderMessage.validateToolName(name)
      self = .named(name)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .automatic:
      try container.encode(Kind.automatic, forKey: .type)
    case .required:
      try container.encode(Kind.required, forKey: .type)
    case .named(let name):
      try ProviderMessage.validateToolName(name)
      try container.encode(Kind.named, forKey: .type)
      try container.encode(name, forKey: .name)
    }
  }
}

public enum ProviderOutputRequirement: Codable, Equatable, Sendable {
  case text
  /// Requests valid JSON while the caller retains exact schema enforcement.
  /// Adapters use only JSON constraints qualified for their wire dialect.
  case applicationValidatedJSON(name: String, schema: ProviderJSONValue)
  /// Requires native provider-side JSON Schema enforcement. Adapters must
  /// reject this case rather than silently degrading it.
  case jsonSchema(name: String, schema: ProviderJSONValue, strict: Bool)

  private enum CodingKeys: String, CodingKey {
    case type
    case name
    case schema
    case strict
  }

  private enum Kind: String, Codable {
    case text
    case applicationValidatedJSON = "application_validated_json"
    case jsonSchema = "json_schema"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .text:
      self = .text
    case .applicationValidatedJSON:
      let name = try container.decode(String.self, forKey: .name)
      let schema = try container.decode(ProviderJSONValue.self, forKey: .schema)
      try Self.validate(name: name, schema: schema)
      self = .applicationValidatedJSON(name: name, schema: schema)
    case .jsonSchema:
      let name = try container.decode(String.self, forKey: .name)
      let schema = try container.decode(ProviderJSONValue.self, forKey: .schema)
      try Self.validate(name: name, schema: schema)
      self = .jsonSchema(
        name: name,
        schema: schema,
        strict: try container.decode(Bool.self, forKey: .strict)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text:
      try container.encode(Kind.text, forKey: .type)
    case .applicationValidatedJSON(let name, let schema):
      try Self.validate(name: name, schema: schema)
      try container.encode(Kind.applicationValidatedJSON, forKey: .type)
      try container.encode(name, forKey: .name)
      try container.encode(schema, forKey: .schema)
    case .jsonSchema(let name, let schema, let strict):
      try Self.validate(name: name, schema: schema)
      try container.encode(Kind.jsonSchema, forKey: .type)
      try container.encode(name, forKey: .name)
      try container.encode(schema, forKey: .schema)
      try container.encode(strict, forKey: .strict)
    }
  }

  private static func validate(name: String, schema: ProviderJSONValue) throws {
    try ProviderMessage.validateToolName(name)
    guard schema.objectValue != nil else {
      throw ProviderCoreError(code: .invalidRequest, message: "output schema must be an object")
    }
    _ = try schema.validated()
  }
}

public enum ProviderReasoningEffort: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
}

public enum ProviderReasoningPolicy: Codable, Equatable, Sendable {
  case disabled
  case automatic
  case effort(ProviderReasoningEffort)
}

public struct ProviderContinuation: Codable, Equatable, Sendable {
  public let providerID: ProviderID
  public let accountID: ProviderAccountID
  public let value: String

  public init(
    providerID: ProviderID,
    accountID: ProviderAccountID,
    value: String
  ) throws {
    guard !value.isEmpty,
      value.utf8.count <= 8_192,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider continuation is invalid")
    }
    self.providerID = providerID
    self.accountID = accountID
    self.value = value
  }
}

public enum ProviderDataCollectionPolicy: String, Codable, Sendable {
  case deny
  case allow
}

public struct ProviderRequestConstraints: Codable, Equatable, Sendable {
  public let dataCollection: ProviderDataCollectionPolicy
  public let requiresZeroDataRetention: Bool
  public let requiresParameterSupport: Bool
  /// Endpoint fallback is forbidden by ProviderKit policy and must be `false`.
  ///
  /// The stored value exists so Codable requests retain the full privacy and
  /// routing contract, including when sent to compatible provider dialects.
  public let allowsProviderEndpointFallbacks: Bool
  public let timeoutMilliseconds: UInt64
  public let maximumResponseBytes: Int
  /// Maximum total transport attempts, including the initial attempt.
  ///
  /// `1` disables retries; `2` permits one retry before visible output.
  public let maximumRetryAttempts: Int
  public let maximumOutputTokens: Int?

  public init(
    dataCollection: ProviderDataCollectionPolicy = .deny,
    requiresZeroDataRetention: Bool = true,
    requiresParameterSupport: Bool = true,
    allowsProviderEndpointFallbacks: Bool = false,
    timeoutMilliseconds: UInt64 = 300_000,
    maximumResponseBytes: Int = 16 * 1_024 * 1_024,
    maximumRetryAttempts: Int = 1,
    maximumOutputTokens: Int? = nil
  ) throws {
    guard !allowsProviderEndpointFallbacks,
      timeoutMilliseconds >= 1_000,
      timeoutMilliseconds <= 3_600_000,
      maximumResponseBytes >= 1_024,
      maximumResponseBytes <= 64 * 1_024 * 1_024,
      maximumRetryAttempts >= 1,
      maximumRetryAttempts <= 3,
      maximumOutputTokens.map({ (1...1_000_000).contains($0) }) ?? true
    else {
      throw ProviderCoreError(code: .invalidRequest, message: "provider constraints are invalid")
    }
    self.dataCollection = dataCollection
    self.requiresZeroDataRetention = requiresZeroDataRetention
    self.requiresParameterSupport = requiresParameterSupport
    self.allowsProviderEndpointFallbacks = allowsProviderEndpointFallbacks
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumRetryAttempts = maximumRetryAttempts
    self.maximumOutputTokens = maximumOutputTokens
  }
}

public struct ProviderTurnRequest: Codable, Equatable, Sendable {
  public static let maximumMessages = 512
  public static let maximumTools = 128

  public let id: ProviderRequestID
  public let selection: ProviderSelection
  public let messages: [ProviderMessage]
  public let tools: [ProviderToolDefinition]
  public let toolChoice: ProviderToolChoice
  public let output: ProviderOutputRequirement
  public let reasoning: ProviderReasoningPolicy
  public let continuation: ProviderContinuation?
  public let constraints: ProviderRequestConstraints

  public init(
    id: ProviderRequestID,
    selection: ProviderSelection,
    messages: [ProviderMessage],
    tools: [ProviderToolDefinition] = [],
    toolChoice: ProviderToolChoice = .automatic,
    output: ProviderOutputRequirement = .text,
    reasoning: ProviderReasoningPolicy = .automatic,
    continuation: ProviderContinuation? = nil,
    constraints: ProviderRequestConstraints
  ) throws {
    guard !messages.isEmpty,
      messages.count <= Self.maximumMessages,
      tools.count <= Self.maximumTools,
      Set(tools.map(\.name)).count == tools.count,
      messages.last?.role == .user || messages.last?.role == .tool
    else {
      throw ProviderCoreError(
        code: .invalidRequest,
        message: "provider request messages or tools violate bounds"
      )
    }
    if let continuation,
      continuation.providerID != selection.providerID
        || continuation.accountID != selection.accountID
    {
      throw ProviderCoreError(
        code: .invalidRequest,
        message: "provider continuation belongs to another provider account"
      )
    }
    try Self.validateToolHistory(messages, requiresLocalToolCalls: continuation == nil)
    switch toolChoice {
    case .automatic:
      break
    case .required:
      guard !tools.isEmpty else {
        throw ProviderCoreError(
          code: .invalidRequest,
          message: "required tool choice needs at least one tool"
        )
      }
    case .named(let name):
      try ProviderMessage.validateToolName(name)
      guard tools.contains(where: { $0.name == name }) else {
        throw ProviderCoreError(
          code: .invalidRequest,
          message: "named tool choice must reference a supplied tool"
        )
      }
    }
    switch output {
    case .text:
      break
    case .applicationValidatedJSON(let name, let schema),
      .jsonSchema(let name, let schema, _):
      try ProviderMessage.validateToolName(name)
      guard schema.objectValue != nil else {
        throw ProviderCoreError(code: .invalidRequest, message: "output schema must be an object")
      }
      _ = try schema.validated()
    }
    self.id = id
    self.selection = selection
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.output = output
    self.reasoning = reasoning
    self.continuation = continuation
    self.constraints = constraints
  }

  private static func validateToolHistory(
    _ messages: [ProviderMessage],
    requiresLocalToolCalls: Bool
  ) throws {
    var calls: [String: String] = [:]
    var results = Set<String>()
    for message in messages {
      for content in message.content {
        switch content {
        case .toolCall(let callID, let name, _):
          guard calls[callID] == nil else {
            throw ProviderCoreError(
              code: .invalidRequest,
              message: "provider request repeats a tool call ID"
            )
          }
          calls[callID] = name
        case .toolResult(let callID, let name, _):
          if let expectedName = calls[callID] {
            guard expectedName == name else {
              throw ProviderCoreError(
                code: .invalidRequest,
                message: "provider tool result name does not match its call"
              )
            }
          } else if requiresLocalToolCalls {
            throw ProviderCoreError(
              code: .invalidRequest,
              message: "provider tool result has no preceding assistant tool call"
            )
          }
          guard results.insert(callID).inserted else {
            throw ProviderCoreError(
              code: .invalidRequest,
              message: "provider request repeats a tool result"
            )
          }
        case .text:
          break
        }
      }
    }
    if requiresLocalToolCalls,
      let unresolvedCallID = calls.keys.first(where: { !results.contains($0) })
    {
      throw ProviderCoreError(
        code: .invalidRequest,
        message: "provider assistant tool call has no matching tool result: \(unresolvedCallID)"
      )
    }
  }
}

public enum ProviderCapabilitySource: String, Codable, Sendable {
  case providerDocumentation = "provider_documentation"
  case providerModelCatalog = "provider_model_catalog"
  case accountInspection = "account_inspection"
}

public enum CapabilitySupport: Codable, Equatable, Sendable {
  case verified(ProviderConformanceReceiptID)
  case declared(ProviderCapabilitySource)
  case unsupported
  case unknown
}

public struct ProviderCapabilities: Codable, Equatable, Sendable {
  public let streaming: CapabilitySupport
  public let toolCalling: CapabilitySupport
  public let parallelToolCalling: CapabilitySupport
  public let structuredOutput: CapabilitySupport
  public let reasoningContinuity: CapabilitySupport
  public let usageReporting: CapabilitySupport

  public init(
    streaming: CapabilitySupport = .unknown,
    toolCalling: CapabilitySupport = .unknown,
    parallelToolCalling: CapabilitySupport = .unknown,
    structuredOutput: CapabilitySupport = .unknown,
    reasoningContinuity: CapabilitySupport = .unknown,
    usageReporting: CapabilitySupport = .unknown
  ) {
    self.streaming = streaming
    self.toolCalling = toolCalling
    self.parallelToolCalling = parallelToolCalling
    self.structuredOutput = structuredOutput
    self.reasoningContinuity = reasoningContinuity
    self.usageReporting = usageReporting
  }
}

public struct ProviderModelDescriptor: Codable, Equatable, Sendable {
  public let id: ProviderModelID
  public let displayName: String?
  public let capabilities: ProviderCapabilities
  public let contextTokenLimit: Int?
  public let maximumOutputTokens: Int?

  public init(
    id: ProviderModelID,
    displayName: String? = nil,
    capabilities: ProviderCapabilities = .init(),
    contextTokenLimit: Int? = nil,
    maximumOutputTokens: Int? = nil
  ) throws {
    if let displayName {
      guard !displayName.isEmpty,
        displayName.utf8.count <= 256,
        !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(code: .invalidValue, message: "model display name is invalid")
      }
    }
    if let contextTokenLimit, contextTokenLimit <= 0 {
      throw ProviderCoreError(code: .invalidValue, message: "model context limit is invalid")
    }
    if let maximumOutputTokens, maximumOutputTokens <= 0 {
      throw ProviderCoreError(code: .invalidValue, message: "model output limit is invalid")
    }
    self.id = id
    self.displayName = displayName
    self.capabilities = capabilities
    self.contextTokenLimit = contextTokenLimit
    self.maximumOutputTokens = maximumOutputTokens
  }
}

public struct ProviderModelCatalogResult: Codable, Equatable, Sendable {
  public let models: [ProviderModelDescriptor]
  public let refreshedAt: Date

  public init(models: [ProviderModelDescriptor], refreshedAt: Date) throws {
    try ProviderValueValidation.finiteDate(refreshedAt, field: "model catalog refresh date")
    let identifiers = models.map(\.id)
    guard Set(identifiers).count == identifiers.count else {
      throw ProviderCoreError(code: .invalidValue, message: "model catalog contains duplicates")
    }
    self.models = models.sorted { $0.id.rawValue < $1.id.rawValue }
    self.refreshedAt = refreshedAt
  }
}
