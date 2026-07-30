import Foundation
import SEMIProviderCore

/// Pure parser for the bounded loopback OAuth callback request. It validates
/// the HTTP origin, callback path, and anti-CSRF state before the listener can
/// consume the authorization session.
struct LoopbackOAuthCallbackParser {
  static func parse(
    _ data: Data,
    baseURL: URL,
    callbackPath: String,
    expectedState: String,
    maximumBytes: Int
  ) throws -> URL {
    guard maximumBytes > 0,
      data.count <= maximumBytes,
      expectedState.utf8.count > 0,
      expectedState.utf8.count <= 512,
      let request = String(data: data, encoding: .utf8),
      let headerEnd = request.range(of: "\r\n\r\n"),
      let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      base.scheme?.lowercased() == "http",
      base.host?.lowercased() == "127.0.0.1",
      let port = base.port,
      base.percentEncodedPath == callbackPath,
      base.query == nil,
      base.fragment == nil,
      base.user == nil,
      base.password == nil
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "loopback OAuth callback is malformed"
      )
    }

    let headerLines = request[..<headerEnd.lowerBound].split(separator: "\r\n")
    guard let requestLine = headerLines.first else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "loopback OAuth callback is malformed"
      )
    }
    let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    let hosts = headerLines.dropFirst().compactMap { line -> String? in
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "host"
      else { return nil }
      return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    guard fields.count == 3,
      fields[0] == "GET",
      fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1",
      hosts == ["127.0.0.1:\(port)"],
      fields[1].utf8.count <= maximumBytes,
      let targetURL = URL(string: String(fields[1]), relativeTo: baseURL),
      let target = URLComponents(
        url: targetURL.absoluteURL,
        resolvingAgainstBaseURL: false
      ),
      target.scheme?.lowercased() == "http",
      target.host?.lowercased() == "127.0.0.1",
      target.port == port,
      target.percentEncodedPath == callbackPath,
      target.fragment == nil,
      target.user == nil,
      target.password == nil
    else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "loopback OAuth callback origin or path is invalid"
      )
    }

    let states = (target.queryItems ?? []).filter { $0.name == "state" }
    guard states.count == 1, states[0].value == expectedState else {
      throw ProviderFailure(
        code: .authenticationFailed,
        message: "loopback OAuth callback state is invalid"
      )
    }
    return targetURL.absoluteURL
  }
}
