import Foundation

public struct SensitiveValue: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  private let storage: String

  public init(_ value: String) throws {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.utf8.count <= 64 * 1_024,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "credential value is invalid")
    }
    self.storage = value
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "SensitiveValue(<redacted>)" }

  package var revealed: String { storage }
}

public enum ProviderCredentialSource: String, Codable, CaseIterable, Sendable {
  case apiKey = "api_key"
  case bearerToken = "bearer_token"
  case oauthDerivedKey = "oauth_derived_key"
  case externalAuthFileReference = "external_auth_file_reference"
}

public enum ProviderCredentialMaterial: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  case apiKey(SensitiveValue)
  case bearerToken(SensitiveValue)
  case oauthDerivedKey(SensitiveValue)
  /// An already-authorized ChatGPT account credential supplied by the host.
  /// The access token is never persisted by ProviderKit's record metadata.
  case openAIAccount(accessToken: SensitiveValue, accountID: String)
  case externalAuthFile(path: String)

  public var source: ProviderCredentialSource {
    switch self {
    case .apiKey: .apiKey
    case .bearerToken: .bearerToken
    case .oauthDerivedKey: .oauthDerivedKey
    case .openAIAccount: .oauthDerivedKey
    case .externalAuthFile: .externalAuthFileReference
    }
  }

  public static func chatGPTAccount(
    accessToken: SensitiveValue,
    accountID: String
  ) throws -> ProviderCredentialMaterial {
    guard accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty,
      accountID.utf8.count <= 512,
      !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "OpenAI account ID is invalid")
    }
    return .openAIAccount(accessToken: accessToken, accountID: accountID)
  }

  public init(externalAuthFilePath path: String) throws {
    guard path.hasPrefix("/"),
      path.utf8.count <= 4_096,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "external auth path is invalid")
    }
    self = .externalAuthFile(path: path)
  }

  public var description: String { "ProviderCredentialMaterial(<redacted>)" }
  public var debugDescription: String { description }
}

public struct ProviderEndpointConfiguration: Codable, Equatable, Sendable {
  public let baseURL: URL

  public init(baseURL: URL) throws {
    guard baseURL.scheme?.lowercased() == "https",
      baseURL.user == nil,
      baseURL.password == nil,
      baseURL.fragment == nil,
      baseURL.query == nil,
      baseURL.host != nil
    else {
      throw ProviderCoreError(
        code: .invalidValue,
        message: "provider endpoint must be an absolute HTTPS URL without user information"
      )
    }
    self.baseURL = baseURL
  }
}

/// Non-secret, provider-specific routing values attached to one account.
/// Credentials must remain in `ProviderCredentialMaterial` and never be put
/// in this metadata container.
public struct ProviderAccountOptions: Codable, Equatable, Sendable {
  public let values: [String: String]

  public init(values: [String: String]) throws {
    guard values.count <= 16 else {
      throw ProviderCoreError(
        code: .invalidValue, message: "provider account options are oversized")
    }
    for (key, value) in values {
      guard !key.isEmpty,
        key.utf8.count <= 64,
        key.utf8.allSatisfy({ byte in
          switch byte {
          case 45, 46, 48...57, 95, 97...122: true
          default: false
          }
        }),
        value == value.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.utf8.count <= 1_024,
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(code: .invalidValue, message: "provider account option is invalid")
      }
    }
    self.values = values
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(values: container.decode([String: String].self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(values)
  }
}

public struct ProviderAccountRegistrationRequest: Equatable, Sendable {
  public let accountID: ProviderAccountID
  public let providerID: ProviderID
  public let label: String
  public let credential: ProviderCredentialMaterial
  public let endpoint: ProviderEndpointConfiguration?
  public let options: ProviderAccountOptions?

  public init(
    accountID: ProviderAccountID,
    providerID: ProviderID,
    label: String,
    credential: ProviderCredentialMaterial,
    endpoint: ProviderEndpointConfiguration? = nil,
    options: ProviderAccountOptions? = nil
  ) throws {
    guard label == label.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty,
      label.utf8.count <= 128,
      !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "provider account label is invalid")
    }
    self.accountID = accountID
    self.providerID = providerID
    self.label = label
    self.credential = credential
    self.endpoint = endpoint
    self.options = options
  }
}

public enum ProviderCredentialRecordState: String, Codable, Sendable {
  case staged
  case active
}

public struct ProviderCredentialRecord: Codable, Equatable, Sendable {
  public let reference: ProviderCredentialReference
  public let accountID: ProviderAccountID
  public let providerID: ProviderID
  public let label: String
  public let source: ProviderCredentialSource
  public let state: ProviderCredentialRecordState
  public let endpoint: ProviderEndpointConfiguration?
  public let options: ProviderAccountOptions?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    reference: ProviderCredentialReference,
    accountID: ProviderAccountID,
    providerID: ProviderID,
    label: String,
    source: ProviderCredentialSource,
    state: ProviderCredentialRecordState,
    endpoint: ProviderEndpointConfiguration?,
    options: ProviderAccountOptions? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.reference = reference
    self.accountID = accountID
    self.providerID = providerID
    self.label = label
    self.source = source
    self.state = state
    self.endpoint = endpoint
    self.options = options
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ProviderCredentialLease: Sendable {
  public let record: ProviderCredentialRecord
  public let material: ProviderCredentialMaterial

  public init(record: ProviderCredentialRecord, material: ProviderCredentialMaterial) {
    self.record = record
    self.material = material
  }
}

public enum ProviderAccountReadiness: String, Codable, Sendable {
  case ready
  case verificationRequired = "verification_required"
  case unconfigured
  case unavailable
  case recoveryRequired = "recovery_required"
}

public struct ProviderAccountInspection: Codable, Equatable, Sendable {
  public let accountID: ProviderAccountID
  public let providerID: ProviderID
  public let readiness: ProviderAccountReadiness
  public let message: String?
  public let capabilities: ProviderCapabilities
  public let inspectedAt: Date

  public init(
    accountID: ProviderAccountID,
    providerID: ProviderID,
    readiness: ProviderAccountReadiness,
    message: String? = nil,
    capabilities: ProviderCapabilities = .init(),
    inspectedAt: Date
  ) throws {
    try ProviderValueValidation.finiteDate(inspectedAt, field: "account inspection date")
    if let message {
      guard !message.isEmpty,
        message.utf8.count <= 1_024,
        !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderCoreError(
          code: .invalidValue, message: "account inspection message is invalid")
      }
    }
    self.accountID = accountID
    self.providerID = providerID
    self.readiness = readiness
    self.message = message
    self.capabilities = capabilities
    self.inspectedAt = inspectedAt
  }
}

public struct ProviderAccountSummary: Codable, Equatable, Sendable {
  public let accountID: ProviderAccountID
  public let providerID: ProviderID
  public let label: String
  public let credentialSource: ProviderCredentialSource
  public let readiness: ProviderAccountReadiness
  public let endpoint: ProviderEndpointConfiguration?
  public let lastInspectedAt: Date?

  public init(
    accountID: ProviderAccountID,
    providerID: ProviderID,
    label: String,
    credentialSource: ProviderCredentialSource,
    readiness: ProviderAccountReadiness,
    endpoint: ProviderEndpointConfiguration?,
    lastInspectedAt: Date?
  ) {
    self.accountID = accountID
    self.providerID = providerID
    self.label = label
    self.credentialSource = credentialSource
    self.readiness = readiness
    self.endpoint = endpoint
    self.lastInspectedAt = lastInspectedAt
  }
}

public struct ProviderCredentialReconciliationIssue: Codable, Equatable, Sendable {
  public let reference: ProviderCredentialReference
  public let accountID: ProviderAccountID
  public let failure: ProviderFailure

  public init(
    reference: ProviderCredentialReference,
    accountID: ProviderAccountID,
    failure: ProviderFailure
  ) {
    self.reference = reference
    self.accountID = accountID
    self.failure = failure
  }
}

public struct ProviderCredentialReconciliationReport: Codable, Equatable, Sendable {
  public let activeRecordCount: Int
  public let removedStagedReferences: [ProviderCredentialReference]
  public let issues: [ProviderCredentialReconciliationIssue]

  public init(
    activeRecordCount: Int,
    removedStagedReferences: [ProviderCredentialReference],
    issues: [ProviderCredentialReconciliationIssue]
  ) throws {
    guard activeRecordCount >= 0 else {
      throw ProviderCoreError(
        code: .invalidValue,
        message: "active credential record count is invalid"
      )
    }
    self.activeRecordCount = activeRecordCount
    self.removedStagedReferences = removedStagedReferences.sorted {
      $0.rawValue < $1.rawValue
    }
    self.issues = issues.sorted {
      if $0.accountID != $1.accountID {
        return $0.accountID.rawValue < $1.accountID.rawValue
      }
      return $0.reference.rawValue < $1.reference.rawValue
    }
  }

  public var requiresRecovery: Bool { !issues.isEmpty }
}

/// Storage boundary for provider credentials and their registration state.
///
/// Conforming types choose the durability and protection policy. The protocol
/// itself does not imply encryption or persistence.
public protocol ProviderCredentialStore: Sendable {
  func stage(
    _ request: ProviderAccountRegistrationRequest,
    at date: Date
  ) async throws -> ProviderCredentialRecord
  func activate(_ record: ProviderCredentialRecord, at date: Date) async throws
  func remove(_ record: ProviderCredentialRecord) async throws
  func record(accountID: ProviderAccountID) async throws -> ProviderCredentialRecord?
  func lease(accountID: ProviderAccountID) async throws -> ProviderCredentialLease
  func records() async throws -> [ProviderCredentialRecord]
}

public struct ProviderAuthorizationRequest: Sendable {
  public let providerID: ProviderID
  public let authorizationURL: URL
  public let callbackScheme: String
  public let state: String

  public init(
    providerID: ProviderID,
    authorizationURL: URL,
    callbackScheme: String,
    state: String
  ) throws {
    let callbackBytes = Array(callbackScheme.utf8)
    guard authorizationURL.scheme?.lowercased() == "https",
      authorizationURL.host != nil,
      authorizationURL.user == nil,
      authorizationURL.password == nil,
      authorizationURL.fragment == nil,
      !callbackBytes.isEmpty,
      callbackBytes.count <= 128,
      callbackBytes[0].isASCIILetter,
      callbackBytes.dropFirst().allSatisfy({ byte in
        byte.isASCIILetter || byte.isASCIIDigit || byte == 43 || byte == 45 || byte == 46
      }),
      !state.isEmpty,
      state.utf8.count <= 512,
      !state.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "authorization request is invalid")
    }
    self.providerID = providerID
    self.authorizationURL = authorizationURL
    self.callbackScheme = callbackScheme
    self.state = state
  }
}

public struct ProviderAuthorizationResult: Sendable, Equatable {
  public let callbackURL: URL

  public init(callbackURL: URL) {
    self.callbackURL = callbackURL
  }
}

public protocol ProviderAuthorizationSession: Sendable {
  func authorize(
    _ request: ProviderAuthorizationRequest
  ) async throws -> ProviderAuthorizationResult
  func cancel() async
}

public protocol ProviderClock: Sendable {
  func now() async -> Date
  func sleep(milliseconds: UInt64) async throws
}

public struct SystemProviderClock: ProviderClock {
  public init() {}

  public func now() async -> Date { Date() }

  public func sleep(milliseconds: UInt64) async throws {
    let (nanoseconds, overflowed) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
    guard !overflowed else {
      throw ProviderCoreError(code: .invalidValue, message: "sleep duration overflow")
    }
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

extension UInt8 {
  fileprivate var isASCIILetter: Bool {
    (65...90).contains(self) || (97...122).contains(self)
  }

  fileprivate var isASCIIDigit: Bool { (48...57).contains(self) }
}
