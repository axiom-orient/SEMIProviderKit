import Foundation
import SEMIProviderCore

public struct OpenRouterOAuthRegistrationRequest: Sendable {
  public let accountID: ProviderAccountID
  public let label: String
  public let callbackURL: URL
  public let pkce: ProviderPKCE

  public init(
    accountID: ProviderAccountID,
    label: String,
    callbackURL: URL,
    pkce: ProviderPKCE
  ) throws {
    guard label == label.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty,
      label.utf8.count <= 128,
      !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderCoreError(code: .invalidValue, message: "OpenRouter account label is invalid")
    }
    try Self.validate(callbackURL: callbackURL)
    self.accountID = accountID
    self.label = label
    self.callbackURL = callbackURL
    self.pkce = pkce
  }

  private static func validate(callbackURL: URL) throws {
    guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      !scheme.isEmpty,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      !(components.queryItems ?? []).contains(where: { item in
        item.name == "code" || item.name == "error" || item.name == "state"
      })
    else {
      throw ProviderCoreError(code: .invalidValue, message: "OpenRouter callback URL is invalid")
    }

    if scheme == "https" {
      guard components.host != nil else {
        throw ProviderCoreError(code: .invalidValue, message: "HTTPS callback URL has no host")
      }
    } else if scheme == "http" {
      let host = components.host?.lowercased()
      guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
        throw ProviderCoreError(
          code: .invalidValue,
          message: "plain HTTP callback URL is restricted to loopback hosts"
        )
      }
    } else {
      throw ProviderCoreError(
        code: .invalidValue,
        message: "OpenRouter callback must use HTTPS or a loopback HTTP URL"
      )
    }

    components.scheme = scheme
    guard components.url != nil else {
      throw ProviderCoreError(code: .invalidValue, message: "OpenRouter callback URL is invalid")
    }
  }
}

package struct OpenRouterOAuthBroker: Sendable {
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderClock

  package init(
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) {
    self.transport = transport
    self.clock = clock
  }

  package func authorize(
    _ request: OpenRouterOAuthRegistrationRequest,
    using authorizationSession: any ProviderAuthorizationSession
  ) async throws -> ProviderAccountRegistrationRequest {
    let callbackURL = try callbackURLWithState(request.callbackURL, state: request.pkce.state)
    let authorizationURL = try makeAuthorizationURL(callbackURL: callbackURL, pkce: request.pkce)
    let callbackScheme = try requireCallbackScheme(callbackURL)
    let authorizationRequest = try ProviderAuthorizationRequest(
      providerID: BuiltInProviderID.openRouter,
      authorizationURL: authorizationURL,
      callbackScheme: callbackScheme,
      state: request.pkce.state
    )

    let result = try await withTaskCancellationHandler {
      try await authorizationSession.authorize(authorizationRequest)
    } onCancel: {
      Task { await authorizationSession.cancel() }
    }
    try Task.checkCancellation()
    let code = try validateCallback(
      result.callbackURL,
      expectedCallbackURL: callbackURL,
      expectedState: request.pkce.state
    )
    let key = try await exchange(code: code, pkce: request.pkce)
    return try ProviderAccountRegistrationRequest(
      accountID: request.accountID,
      providerID: BuiltInProviderID.openRouter,
      label: request.label,
      credential: .oauthDerivedKey(key)
    )
  }

  private func callbackURLWithState(_ callbackURL: URL, state: String) throws -> URL {
    guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw ProviderFailure(code: .invalidRequest, message: "OpenRouter callback URL is invalid")
    }
    var query = components.queryItems ?? []
    query.append(URLQueryItem(name: "state", value: state))
    components.queryItems = query
    guard let result = components.url else {
      throw ProviderFailure(code: .invalidRequest, message: "OpenRouter callback URL is invalid")
    }
    return result
  }

  private func makeAuthorizationURL(callbackURL: URL, pkce: ProviderPKCE) throws -> URL {
    var components = URLComponents(string: "https://openrouter.ai/auth")
    components?.queryItems = [
      URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
      URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    guard let url = components?.url else {
      throw ProviderFailure(
        code: .internalInvariant,
        message: "OpenRouter authorization URL could not be constructed"
      )
    }
    return url
  }

  private func requireCallbackScheme(_ callbackURL: URL) throws -> String {
    guard let scheme = callbackURL.scheme, !scheme.isEmpty else {
      throw ProviderFailure(code: .invalidRequest, message: "OpenRouter callback scheme is missing")
    }
    return scheme
  }

  private func validateCallback(
    _ callbackURL: URL,
    expectedCallbackURL: URL,
    expectedState: String
  ) throws -> String {
    guard let actual = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      let expected = URLComponents(url: expectedCallbackURL, resolvingAgainstBaseURL: false),
      actual.scheme?.lowercased() == expected.scheme?.lowercased(),
      actual.host?.lowercased() == expected.host?.lowercased(),
      actual.port == expected.port,
      actual.percentEncodedPath == expected.percentEncodedPath,
      actual.user == nil,
      actual.password == nil,
      actual.fragment == nil
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth callback origin or path does not match the request"
      )
    }

    let actualItems = actual.queryItems ?? []
    let expectedItems = expected.queryItems ?? []
    guard exactlyOneValue(named: "state", in: actualItems) == expectedState else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth state does not match the request"
      )
    }

    let code = exactlyOneValue(named: "code", in: actualItems)
    let error = exactlyOneValue(named: "error", in: actualItems)
    guard (code == nil) != (error == nil) else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth callback has an invalid terminal result"
      )
    }

    let responseItem: URLQueryItem
    if let code {
      responseItem = URLQueryItem(name: "code", value: code)
    } else {
      responseItem = URLQueryItem(name: "error", value: error)
    }
    guard queryMultiset(actualItems) == queryMultiset(expectedItems + [responseItem]) else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth callback query does not match the request"
      )
    }

    if let error {
      guard !error.isEmpty,
        error.utf8.count <= 1_024,
        !error.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderFailure(
          code: .authenticationFailed,
          message: "OpenRouter authorization returned an invalid error"
        )
      }
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter authorization failed: \(error)"
      )
    }

    guard let code,
      !code.isEmpty,
      code.utf8.count <= 4_096,
      !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "OpenRouter OAuth callback has no valid authorization code"
      )
    }
    return code
  }

  private struct QueryItem: Hashable {
    let name: String
    let value: String?
  }

  private func queryMultiset(_ items: [URLQueryItem]) -> [QueryItem: Int] {
    items.reduce(into: [:]) { counts, item in
      counts[QueryItem(name: item.name, value: item.value), default: 0] += 1
    }
  }

  private func exactlyOneValue(named name: String, in items: [URLQueryItem]) -> String? {
    let matches = items.filter { $0.name == name }
    guard matches.count == 1, let value = matches[0].value else { return nil }
    return value
  }

  private func exchange(code: String, pkce: ProviderPKCE) async throws -> SensitiveValue {
    let body: ProviderJSONValue = .object([
      "code": .string(code),
      "code_verifier": .string(pkce.codeVerifier.revealed),
      "code_challenge_method": .string("S256"),
    ])
    let constraints = try ProviderRequestConstraints(
      timeoutMilliseconds: 60_000,
      maximumResponseBytes: 1 * 1_024 * 1_024,
      maximumRetryAttempts: 1
    )
    let request = try ProviderWireValidation.makeJSONRequest(
      url: try requireURL("https://openrouter.ai/api/v1/auth/keys"),
      headers: [:],
      body: body,
      constraints: constraints
    )
    let response = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw ProviderWireError.httpFailure(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
        now: await clock.now()
      )
    }
    let root = try ProviderWireValidation.decodeJSON(
      response.body,
      field: "OpenRouter OAuth response JSON"
    )
    guard let rawKey = root["key"]?.stringValue else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "OpenRouter OAuth key exchange returned no API key"
      )
    }
    return try SensitiveValue(rawKey)
  }

  private func requireURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw ProviderFailure(code: .internalInvariant, message: "OpenRouter OAuth URL is invalid")
    }
    return url
  }
}
