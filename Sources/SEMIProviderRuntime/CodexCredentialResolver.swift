import Foundation
import SEMIProviderCore

package struct CodexResolvedCredential: Sendable {
  package let accessToken: String
  package let accountID: String
  package let clientVersion: String
}

/// Resolves caller-owned Codex credential material before a Responses request is built.
/// File security stays outside the wire codec; the package declares its own protocol version.
package enum CodexCredentialResolver {
  private static let maximumAuthBytes = 1 * 1_024 * 1_024

  package static func resolve(_ material: ProviderCredentialMaterial) async throws
    -> CodexResolvedCredential
  {
    let accessToken: String
    let accountID: String
    switch material {
    case .openAIAccount(let token, let account):
      accessToken = token.revealed
      accountID = account
    case .externalAuthFile(let path):
      let authURL = URL(fileURLWithPath: path)
      let auth = try SecureRegularFileReader.read(authURL, maximumBytes: maximumAuthBytes)
      let root = try ProviderJSONValue.decode(from: auth)
      guard let rawAccessToken = root.value(at: "tokens", "access_token")?.stringValue,
        let rawAccountID = root.value(at: "tokens", "account_id")?.stringValue
      else {
        throw ProviderFailure(
          code: .authenticationFailed,
          message: "Codex auth.json does not contain supported ChatGPT credentials"
        )
      }
      do {
        accessToken = try SensitiveValue(rawAccessToken).revealed
      } catch {
        throw ProviderFailure(
          code: .authenticationFailed, message: "Codex auth.json contains an invalid access token")
      }
      accountID = rawAccountID
    case .apiKey, .bearerToken, .oauthDerivedKey:
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "Codex requires a ChatGPT account credential"
      )
    }
    guard accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty,
      accountID.utf8.count <= 512,
      !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "Codex credential does not contain a supported ChatGPT account ID"
      )
    }
    guard (try? SensitiveValue(accessToken)) != nil else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "Codex credential contains an invalid access token"
      )
    }
    let version = CodexClientVersion.resolve()
    return .init(accessToken: accessToken, accountID: accountID, clientVersion: version)
  }
}
