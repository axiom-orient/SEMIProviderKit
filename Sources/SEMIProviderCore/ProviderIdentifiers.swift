import Foundation

public enum ProviderCoreErrorCode: String, Codable, Sendable {
  case invalidIdentifier = "invalid_identifier"
  case invalidValue = "invalid_value"
  case invalidRequest = "invalid_request"
  case invalidTransition = "invalid_transition"
  case generationExhausted = "generation_exhausted"
}

public struct ProviderCoreError: Error, Equatable, Sendable {
  public let code: ProviderCoreErrorCode
  public let message: String

  public init(code: ProviderCoreErrorCode, message: String) {
    self.code = code
    self.message = message
  }
}

private enum ProviderIdentifierValidation {
  static func provider(_ value: String) throws -> String {
    try validate(
      value,
      maximumUTF8Count: 64,
      allows: { byte in
        switch byte {
        case 45, 46, 48...57, 95, 97...122: true
        default: false
        }
      }
    )
  }

  static func opaque(_ value: String, maximumUTF8Count: Int = 192) throws -> String {
    try validate(
      value,
      maximumUTF8Count: maximumUTF8Count,
      allows: { byte in
        switch byte {
        case 33...126 where byte != 34 && byte != 39 && byte != 92: true
        default: false
        }
      }
    )
  }

  private static func validate(
    _ value: String,
    maximumUTF8Count: Int,
    allows: (UInt8) -> Bool
  ) throws -> String {
    guard !value.isEmpty,
      value.utf8.count <= maximumUTF8Count,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.allSatisfy(allows)
    else {
      throw ProviderCoreError(
        code: .invalidIdentifier,
        message: "provider identifier is empty, oversized, or contains unsupported characters"
      )
    }
    return value
  }
}

public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.provider(rawValue)
  }

  public init?(rawValue: String) {
    guard let validated = try? ProviderIdentifierValidation.provider(rawValue) else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.provider(container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ProviderAccountID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.opaque(rawValue)
  }

  public init?(rawValue: String) {
    guard let validated = try? ProviderIdentifierValidation.opaque(rawValue) else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.opaque(container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ProviderModelID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.opaque(rawValue)
  }

  public init?(rawValue: String) {
    guard let validated = try? ProviderIdentifierValidation.opaque(rawValue) else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.opaque(container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ProviderRequestID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.opaque(rawValue, maximumUTF8Count: 128)
  }

  public init?(rawValue: String) {
    guard
      let validated = try? ProviderIdentifierValidation.opaque(
        rawValue,
        maximumUTF8Count: 128
      )
    else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.opaque(
      container.decode(String.self),
      maximumUTF8Count: 128
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ProviderCredentialReference: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.opaque(rawValue, maximumUTF8Count: 128)
  }

  public init?(rawValue: String) {
    guard
      let validated = try? ProviderIdentifierValidation.opaque(
        rawValue,
        maximumUTF8Count: 128
      )
    else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.opaque(
      container.decode(String.self),
      maximumUTF8Count: 128
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ProviderConformanceReceiptID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    self.rawValue = try ProviderIdentifierValidation.opaque(rawValue, maximumUTF8Count: 128)
  }

  public init?(rawValue: String) {
    guard
      let validated = try? ProviderIdentifierValidation.opaque(
        rawValue,
        maximumUTF8Count: 128
      )
    else { return nil }
    self.rawValue = validated
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try ProviderIdentifierValidation.opaque(
      container.decode(String.self),
      maximumUTF8Count: 128
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum BuiltInProviderID {
  public static let soa = required("soa")
  public static let openAI = required("openai")
  public static let anthropic = required("anthropic")
  public static let gemini = required("gemini")
  public static let openRouter = required("openrouter")
  public static let deepSeek = required("deepseek")
  public static let qwen = required("qwen")
  public static let kimi = required("kimi")
  public static let zai = required("zai")
  public static let miniMax = required("minimax")

  private static func required(_ value: String) -> ProviderID {
    guard let identifier = ProviderID(rawValue: value) else {
      preconditionFailure("invalid built-in provider identifier")
    }
    return identifier
  }
}
