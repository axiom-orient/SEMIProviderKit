import Foundation

public enum ProviderJSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  /// A JSON number represented as IEEE-754 binary64.
  ///
  /// This preserves ordinary JSON numeric values, but cannot preserve integer
  /// precision beyond `2^53`. Use a JSON string for identifier-like integers
  /// that require lossless round trips.
  case number(Double)
  case string(String)
  case array([ProviderJSONValue])
  case object([String: ProviderJSONValue])

  public static let maximumDepth = 48
  public static let maximumNodes = 65_536
  public static let maximumEncodedBytes = 4 * 1_024 * 1_024
  public static let maximumStringUTF8Bytes = 1 * 1_024 * 1_024

  public var objectValue: [String: ProviderJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [ProviderJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public func validated() throws -> ProviderJSONValue {
    var nodes = 0
    try validate(depth: 0, nodes: &nodes)
    return self
  }

  public func encodedData() throws -> Data {
    _ = try validated()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumEncodedBytes else {
      throw ProviderCoreError(code: .invalidValue, message: "provider JSON exceeds byte limit")
    }
    return data
  }

  public static func decode(from data: Data) throws -> ProviderJSONValue {
    guard data.count <= maximumEncodedBytes else {
      throw ProviderCoreError(code: .invalidValue, message: "provider JSON exceeds byte limit")
    }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }

  private func validate(depth: Int, nodes: inout Int) throws {
    guard depth <= Self.maximumDepth else {
      throw ProviderCoreError(code: .invalidValue, message: "provider JSON exceeds depth limit")
    }
    let (nextNodeCount, overflowed) = nodes.addingReportingOverflow(1)
    guard !overflowed, nextNodeCount <= Self.maximumNodes else {
      throw ProviderCoreError(code: .invalidValue, message: "provider JSON exceeds node limit")
    }
    nodes = nextNodeCount

    switch self {
    case .null, .bool:
      break
    case .number(let value):
      guard value.isFinite else {
        throw ProviderCoreError(code: .invalidValue, message: "provider JSON number is not finite")
      }
    case .string(let value):
      guard value.utf8.count <= Self.maximumStringUTF8Bytes,
        !value.unicodeScalars.contains(where: { $0.value == 0 })
      else {
        throw ProviderCoreError(
          code: .invalidValue,
          message: "provider JSON string is oversized or contains NUL"
        )
      }
    case .array(let values):
      for value in values {
        try value.validate(depth: depth + 1, nodes: &nodes)
      }
    case .object(let values):
      for (key, value) in values {
        guard !key.isEmpty,
          key.utf8.count <= 1_024,
          !key.unicodeScalars.contains(where: { $0.value == 0 })
        else {
          throw ProviderCoreError(code: .invalidValue, message: "provider JSON key is invalid")
        }
        try value.validate(depth: depth + 1, nodes: &nodes)
      }
    }
  }
}

extension ProviderJSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      guard value.isFinite else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "provider JSON number is not finite"
        )
      }
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ProviderJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: ProviderJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "unsupported provider JSON value"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          .init(codingPath: encoder.codingPath, debugDescription: "number is not finite")
        )
      }
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension ProviderJSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension ProviderJSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ProviderJSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension ProviderJSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}

extension ProviderJSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension ProviderJSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: ProviderJSONValue...) { self = .array(elements) }
}

extension ProviderJSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, ProviderJSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}
