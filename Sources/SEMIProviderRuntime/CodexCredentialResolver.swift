import Foundation
import SEMIProviderCore

package struct CodexResolvedCredential: Sendable {
  package let accessToken: String
  package let accountID: String
  package let clientVersion: String
}

/// Resolves caller-owned Codex credential material before a Responses request is built.
/// File security and client-version discovery stay outside the wire codec.
package enum CodexCredentialResolver {
  private static let maximumAuthBytes = 1 * 1_024 * 1_024

  package static func resolve(_ material: ProviderCredentialMaterial) async throws
    -> CodexResolvedCredential
  {
    guard case .externalAuthFile(let path) = material else {
      throw ProviderFailure(
        code: .authenticationFailed, message: "Codex requires an external auth.json reference")
    }
    let authURL = URL(fileURLWithPath: path)
    let auth = try SecureRegularFileReader.read(authURL, maximumBytes: maximumAuthBytes)
    let root = try ProviderJSONValue.decode(from: auth)
    guard let rawAccessToken = root.value(at: "tokens", "access_token")?.stringValue,
      let accountID = root.value(at: "tokens", "account_id")?.stringValue,
      accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountID.isEmpty,
      accountID.utf8.count <= 512,
      !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "Codex auth.json does not contain supported ChatGPT credentials")
    }
    let accessToken: String
    do {
      accessToken = try SensitiveValue(rawAccessToken).revealed
    } catch {
      throw ProviderFailure(
        code: .authenticationFailed, message: "Codex auth.json contains an invalid access token")
    }
    let version = try await CodexClientVersion.resolve(authURL: authURL)
    return .init(accessToken: accessToken, accountID: accountID, clientVersion: version)
  }
}
