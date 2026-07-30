import Foundation
import Testing

@testable import SEMIProviderApple
@testable import SEMIProviderCore

@Suite("SEMIProviderApple")
struct ProviderAppleTests {
  @Test("PKCE generator matches RFC 7636 S256 vector and redacts verifier")
  func pkceVector() throws {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let pkce = try ProviderPKCEGenerator.make(
      verifier: verifier,
      state: String(repeating: "s", count: 32)
    )
    #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(!pkce.description.contains(verifier))
  }

  @Test("PKCE generator creates bounded unique verifier, challenge, and state")
  func pkceGeneration() throws {
    let first = try ProviderPKCEGenerator.generate()
    let second = try ProviderPKCEGenerator.generate()
    #expect(first.codeChallenge.utf8.count == 43)
    #expect(first.state.utf8.count >= 32)
    #expect(first.codeChallenge != second.codeChallenge)
    #expect(first.state != second.state)
  }

  @Test("Loopback callback parser accepts only the expected origin path and state")
  func loopbackCallbackParserAcceptsExpectedCallback() throws {
    let base = try #require(URL(string: "http://127.0.0.1:54321/oauth/openrouter"))
    let request = Data(
      "GET /oauth/openrouter?code=authorization-code&state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nConnection: close\r\n\r\n"
        .utf8
    )

    let callback = try LoopbackOAuthCallbackParser.parse(
      request,
      baseURL: base,
      callbackPath: "/oauth/openrouter",
      expectedState: "expected-state",
      maximumBytes: 32 * 1_024
    )
    #expect(callback.query?.contains("code=authorization-code") == true)
  }

  @Test("Loopback callback parser rejects wrong or duplicate state without consuming the session")
  func loopbackCallbackParserRejectsInvalidState() throws {
    let base = try #require(URL(string: "http://127.0.0.1:54321/oauth/openrouter"))
    let wrong = Data(
      "GET /oauth/openrouter?code=authorization-code&state=wrong HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        .utf8
    )
    let duplicate = Data(
      "GET /oauth/openrouter?code=authorization-code&state=expected&state=expected HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        .utf8
    )

    #expect(throws: ProviderFailure.self) {
      _ = try LoopbackOAuthCallbackParser.parse(
        wrong,
        baseURL: base,
        callbackPath: "/oauth/openrouter",
        expectedState: "expected",
        maximumBytes: 32 * 1_024
      )
    }
    #expect(throws: ProviderFailure.self) {
      _ = try LoopbackOAuthCallbackParser.parse(
        duplicate,
        baseURL: base,
        callbackPath: "/oauth/openrouter",
        expectedState: "expected",
        maximumBytes: 32 * 1_024
      )
    }
  }

  @Test("Loopback callback parser rejects a different host or path")
  func loopbackCallbackParserRejectsOriginMismatch() throws {
    let base = try #require(URL(string: "http://127.0.0.1:54321/oauth/openrouter"))
    let wrongHost = Data(
      "GET /oauth/openrouter?code=authorization-code&state=expected HTTP/1.1\r\nHost: localhost:54321\r\n\r\n"
        .utf8
    )
    let wrongPath = Data(
      "GET /oauth/other?code=authorization-code&state=expected HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        .utf8
    )

    #expect(throws: ProviderFailure.self) {
      _ = try LoopbackOAuthCallbackParser.parse(
        wrongHost,
        baseURL: base,
        callbackPath: "/oauth/openrouter",
        expectedState: "expected",
        maximumBytes: 32 * 1_024
      )
    }
    #expect(throws: ProviderFailure.self) {
      _ = try LoopbackOAuthCallbackParser.parse(
        wrongPath,
        baseURL: base,
        callbackPath: "/oauth/openrouter",
        expectedState: "expected",
        maximumBytes: 32 * 1_024
      )
    }
  }

  @Test("HTTP header terminator scanner handles byte fragments and overlaps linearly")
  func headerTerminatorScanner() {
    let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nbody".utf8)
    var scanner = HTTPHeaderTerminatorScanner()
    var found = false
    for byte in request {
      if scanner.feed(Data([byte])) {
        found = true
        break
      }
    }
    #expect(found)
    #expect(scanner.scannedByteCount <= request.count)

    var overlap = HTTPHeaderTerminatorScanner()
    let partial = overlap.feed(Data("\r\r\n\r".utf8))
    let completed = overlap.feed(Data("\n".utf8))
    #expect(!partial)
    #expect(completed)
  }

  @Test("Loopback OAuth listener binds before authorization and cancels cleanly")
  func loopbackListenerLifecycle() async throws {
    let prepared = try await AppleLoopbackAuthorizationSession.prepare(
      callbackPath: "/oauth/test"
    )
    #expect(prepared.callbackURL.scheme == "http")
    #expect(prepared.callbackURL.host == "127.0.0.1")
    #expect(prepared.callbackURL.path == "/oauth/test")
    #expect(prepared.callbackURL.port != nil)
    await prepared.session.cancel()
  }
}
