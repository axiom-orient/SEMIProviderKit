import CryptoKit
import Foundation
import SEMIProviderCore
import Security

public enum ProviderPKCEGenerator {
  public static func generate() throws -> ProviderPKCE {
    let verifier = base64URLEncoded(try secureRandomBytes(count: 32))
    let state = base64URLEncoded(try secureRandomBytes(count: 32))
    return try make(verifier: verifier, state: state)
  }

  package static func make(verifier: String, state: String) throws -> ProviderPKCE {
    let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
    return try ProviderPKCE(
      codeVerifier: SensitiveValue(verifier),
      codeChallenge: base64URLEncoded(digest),
      state: state
    )
  }

  private static func secureRandomBytes(count: Int) throws -> Data {
    precondition(count > 0)
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw ProviderFailure(
        code: .internalInvariant,
        message: "secure random generation failed with status \(status)"
      )
    }
    return Data(bytes)
  }

  private static func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
