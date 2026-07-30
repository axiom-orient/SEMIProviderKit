import Foundation

public struct ProviderPKCE: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let codeChallenge: String
  public let state: String
  package let codeVerifier: SensitiveValue

  package init(
    codeVerifier: SensitiveValue,
    codeChallenge: String,
    state: String
  ) throws {
    let verifier = codeVerifier.revealed
    guard (43...128).contains(verifier.utf8.count),
      verifier.utf8.allSatisfy(Self.isUnreserved),
      codeChallenge.utf8.count == 43,
      codeChallenge.utf8.allSatisfy(Self.isBase64URL),
      (32...512).contains(state.utf8.count),
      state.utf8.allSatisfy(Self.isUnreserved)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "PKCE material is invalid")
    }
    self.codeVerifier = codeVerifier
    self.codeChallenge = codeChallenge
    self.state = state
  }

  public var description: String {
    "ProviderPKCE(codeChallenge: \(codeChallenge), state: <redacted>)"
  }

  public var debugDescription: String { description }

  private static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 46, 48...57, 65...90, 95, 97...122, 126: true
    default: false
    }
  }

  private static func isBase64URL(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 48...57, 65...90, 95, 97...122: true
    default: false
    }
  }
}
