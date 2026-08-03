import Foundation
import Testing

@testable import SEMIProviderCore

@Suite("SEMIProviderCore")
struct ProviderCoreTests {
  @Test("PKCE material is bounded, redacted, and rejects malformed values")
  func pkceValidation() throws {
    let verifier = try SensitiveValue(String(repeating: "a", count: 43))
    let value = try ProviderPKCE(
      codeVerifier: verifier,
      codeChallenge: String(repeating: "b", count: 43),
      state: String(repeating: "c", count: 32)
    )
    #expect(!value.description.contains(String(repeating: "c", count: 32)))
    #expect(throws: ProviderCoreError.self) {
      try ProviderPKCE(
        codeVerifier: try SensitiveValue("too-short"),
        codeChallenge: String(repeating: "b", count: 43),
        state: String(repeating: "c", count: 32)
      )
    }
  }

  @Test("Open identifiers validate and round-trip")
  func identifiers() throws {
    #expect(try ProviderID("openrouter") == BuiltInProviderID.openRouter)
    #expect(try ProviderAccountID("account-1").rawValue == "account-1")
    #expect(try ProviderModelID("vendor/model:latest").rawValue == "vendor/model:latest")
    #expect(throws: ProviderCoreError.self) { try ProviderID("OpenRouter") }
    #expect(throws: ProviderCoreError.self) { try ProviderAccountID(" account") }

    let data = try JSONEncoder().encode(BuiltInProviderID.deepSeek)
    #expect(try JSONDecoder().decode(ProviderID.self, from: data) == .init("deepseek"))
  }

  @Test("JSON values are deterministic and bounded")
  func jsonValues() throws {
    let value: ProviderJSONValue = [
      "array": [1, true, nil, "text"],
      "nested": ["value": 2.5],
    ]
    let first = try value.encodedData()
    let second = try value.encodedData()
    #expect(first == second)
    #expect(try ProviderJSONValue.decode(from: first) == value)
    #expect(throws: ProviderCoreError.self) {
      try ProviderJSONValue.number(.infinity).encodedData()
    }

    var tooDeep: ProviderJSONValue = nil
    for _ in 0...ProviderJSONValue.maximumDepth {
      tooDeep = .array([tooDeep])
    }
    #expect(throws: ProviderCoreError.self) { try tooDeep.encodedData() }
  }

  @Test("Assistant tool calls are validated and round-trip with tool results")
  func assistantToolCallHistory() throws {
    let arguments: ProviderJSONValue = ["city": "Seoul"]
    let call = ProviderMessageContent.toolCall(
      callID: "call-1",
      name: "lookup_weather",
      arguments: arguments
    )
    let assistant = try ProviderMessage(role: .assistant, content: [call])
    let result = try ProviderMessage(
      role: .tool,
      content: [.toolResult(callID: "call-1", name: "lookup_weather", value: ["temperature": 22])]
    )
    let decoded = try JSONDecoder().decode(
      ProviderMessage.self,
      from: JSONEncoder().encode(assistant)
    )
    #expect(decoded == assistant)
    #expect(result.role == .tool)
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderMessage(role: .user, content: [call])
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderMessage(
        role: .assistant,
        content: [.toolCall(callID: "call-2", name: "lookup_weather", arguments: .string("bad"))]
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderTurnRequest(
        id: ProviderRequestID("orphan-tool-result"),
        selection: ProviderSelection(
          providerID: BuiltInProviderID.openAI,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("model-1")
        ),
        messages: [
          try ProviderMessage(role: .user, text: "weather"),
          try ProviderMessage(
            role: .tool,
            content: [.toolResult(callID: "missing", name: "lookup_weather", value: [:])]
          ),
        ],
        constraints: ProviderRequestConstraints()
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderTurnRequest(
        id: ProviderRequestID("unresolved-tool-call"),
        selection: ProviderSelection(
          providerID: BuiltInProviderID.openAI,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("model-1")
        ),
        messages: [
          try ProviderMessage(role: .user, text: "weather"),
          assistant,
        ],
        constraints: ProviderRequestConstraints()
      )
    }
  }

  @Test("Tool result error markers are Codable and preserve legacy payloads")
  func toolResultErrorMarkerCodable() throws {
    let failed = ProviderMessageContent.toolResult(
      callID: "call-1",
      name: "lookup_weather",
      value: ["message": "service unavailable"],
      isError: true
    )
    let encoded = try JSONEncoder().encode(failed)
    let encodedValue = try ProviderJSONValue.decode(from: encoded)
    guard case .bool(let encodedIsError) = encodedValue.objectValue?["is_error"] else {
      Issue.record("encoded tool result did not contain a boolean is_error marker")
      return
    }
    #expect(encodedIsError)
    #expect(try JSONDecoder().decode(ProviderMessageContent.self, from: encoded) == failed)

    let legacy = Data(
      #"""
      {"type":"tool_result","call_id":"call-1","name":"lookup_weather","value":{"temperature":22}}
      """#.utf8
    )
    let decodedLegacy = try JSONDecoder().decode(ProviderMessageContent.self, from: legacy)
    guard case .toolResult(_, _, _, let isError) = decodedLegacy else {
      Issue.record("legacy tool result did not decode as a tool result")
      return
    }
    #expect(!isError)

    let sourceCompatible = ProviderMessageContent.toolResult(
      callID: "call-1",
      name: "lookup_weather",
      value: ["temperature": 22]
    )
    guard case .toolResult(_, _, _, let isError) = sourceCompatible else {
      Issue.record("source-compatible tool result did not decode as a tool result")
      return
    }
    #expect(!isError)
  }

  @Test("Turn request keeps provider, account, and model independent")
  func turnRequest() throws {
    let request = try makeRequest()
    #expect(request.selection.providerID == BuiltInProviderID.openRouter)
    #expect(request.selection.accountID.rawValue == "account-1")
    #expect(request.selection.modelID.rawValue == "vendor/model")
    #expect(request.messages.last?.role == .user)

    let otherContinuation = try ProviderContinuation(
      providerID: BuiltInProviderID.openAI,
      accountID: request.selection.accountID,
      value: "response-1"
    )
    #expect(throws: ProviderCoreError.self) {
      try ProviderTurnRequest(
        id: ProviderRequestID("request-2"),
        selection: request.selection,
        messages: request.messages,
        continuation: otherContinuation,
        constraints: ProviderRequestConstraints()
      )
    }

    let otherAccountContinuation = try ProviderContinuation(
      providerID: request.selection.providerID,
      accountID: ProviderAccountID("account-2"),
      value: "response-2"
    )
    #expect(throws: ProviderCoreError.self) {
      try ProviderTurnRequest(
        id: ProviderRequestID("request-3"),
        selection: request.selection,
        messages: request.messages,
        continuation: otherAccountContinuation,
        constraints: ProviderRequestConstraints()
      )
    }
  }

  @Test("Output-token limits are explicit, bounded, and Codable")
  func outputTokenLimits() throws {
    let constraints = try ProviderRequestConstraints(maximumOutputTokens: 128_000)
    #expect(constraints.maximumOutputTokens == 128_000)
    let data = try JSONEncoder().encode(constraints)
    #expect(
      try JSONDecoder().decode(ProviderRequestConstraints.self, from: data) == constraints
    )
    #expect(throws: ProviderCoreError.self) {
      try ProviderRequestConstraints(maximumOutputTokens: 0)
    }
    #expect(throws: ProviderCoreError.self) {
      try ProviderRequestConstraints(maximumOutputTokens: 1_000_001)
    }

    let descriptor = try ProviderModelDescriptor(
      id: ProviderModelID("model-with-limits"),
      contextTokenLimit: 200_000,
      maximumOutputTokens: 64_000
    )
    #expect(descriptor.maximumOutputTokens == 64_000)
    #expect(
      try JSONDecoder().decode(
        ProviderModelDescriptor.self,
        from: JSONEncoder().encode(descriptor)
      ) == descriptor
    )
  }

  @Test("Application-validated JSON contracts round-trip and remain bounded")
  func applicationValidatedJSONContract() throws {
    let value = ProviderOutputRequirement.applicationValidatedJSON(
      name: "asa_plan",
      schema: [
        "type": "object",
        "properties": ["summary": ["type": "string"]],
        "required": ["summary"],
        "additionalProperties": false,
      ]
    )
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(ProviderOutputRequirement.self, from: data) == value)
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderTurnRequest(
        id: ProviderRequestID("request-invalid-output"),
        selection: ProviderSelection(
          providerID: BuiltInProviderID.openAI,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("model-1")
        ),
        messages: [try ProviderMessage(role: .user, text: "json")],
        output: .applicationValidatedJSON(name: "invalid name", schema: [:]),
        constraints: ProviderRequestConstraints()
      )
    }
  }

  @Test("Account reducer stages, verifies, and activates before readiness")
  func accountReducerSuccess() throws {
    let request = try registration()
    var state = ProviderAccountState()
    var effects: [ProviderAccountEffect]
    (state, effects) = try ProviderAccountReducer.reduce(
      state: state,
      event: .registrationRequested(request)
    )
    #expect(state.generation == 1)
    #expect(effects.count == 2)

    let record = try credentialRecord(request: request, state: .staged)
    (state, effects) = try ProviderAccountReducer.reduce(
      state: state,
      event: .credentialStaged(record)
    )
    #expect(effects.count == 2)

    let inspection = try ProviderAccountInspection(
      accountID: request.accountID,
      providerID: request.providerID,
      readiness: .ready,
      inspectedAt: Date(timeIntervalSince1970: 10)
    )
    (state, effects) = try ProviderAccountReducer.reduce(
      state: state,
      event: .verificationSucceeded(inspection)
    )
    #expect(effects.count == 2)

    (state, effects) = try ProviderAccountReducer.reduce(
      state: state,
      event: .activationSucceeded
    )
    guard case .ready(let summary) = state.phase else {
      Issue.record("account did not become ready")
      return
    }
    #expect(summary.accountID == request.accountID)
    #expect(effects.count == 1)
  }

  @Test("Account compensation failure is explicit recoveryRequired")
  func accountCompensation() throws {
    let request = try registration()
    var state = ProviderAccountState()
    (state, _) = try ProviderAccountReducer.reduce(
      state: state,
      event: .registrationRequested(request)
    )
    let record = try credentialRecord(request: request, state: .staged)
    (state, _) = try ProviderAccountReducer.reduce(
      state: state,
      event: .credentialStaged(record)
    )
    (state, _) = try ProviderAccountReducer.reduce(
      state: state,
      event: .operationFailed(
        .init(code: .authenticationFailed, message: "invalid credential")
      )
    )
    let compensationTransition = try ProviderAccountReducer.reduce(
      state: state,
      event: .compensationFailed(
        .init(code: .credentialRecoveryRequired, message: "credential removal failed")
      )
    )
    state = compensationTransition.0
    let effects = compensationTransition.1
    guard case .recoveryRequired(let retainedRecord, let failure) = state.phase else {
      Issue.record("compensation failure was hidden")
      return
    }
    #expect(retainedRecord.reference == record.reference)
    #expect(failure.code == .credentialRecoveryRequired)
    #expect(effects.count == 1)
  }

  @Test("Execution publishes terminal only after cleanup")
  func executionCleanupOrdering() throws {
    let request = try makeRequest()
    var state = ProviderExecutionState()
    let admittedTransition = try ProviderExecutionReducer.reduce(
      state: state,
      event: .requestAdmitted(request)
    )
    state = admittedTransition.0
    let admitted = admittedTransition.1
    #expect(admitted.count == 1)

    let metadata = try ProviderResponseMetadata(
      requestID: request.id,
      providerRequestID: "remote-1",
      providerID: request.selection.providerID,
      modelID: request.selection.modelID,
      startedAt: Date(timeIntervalSince1970: 1)
    )
    let openedTransition = try ProviderExecutionReducer.reduce(
      state: state,
      event: .transportOpened(metadata)
    )
    state = openedTransition.0
    let opened = openedTransition.1
    #expect(opened == [.publish(.started(metadata))])

    let completion = try ProviderCompletion(finishedAt: Date(timeIntervalSince1970: 2))
    let terminatingTransition = try ProviderExecutionReducer.reduce(
      state: state,
      event: .transportCompleted(completion)
    )
    state = terminatingTransition.0
    let terminating = terminatingTransition.1
    #expect(terminating == [.beginCleanup(cancelTransport: false, generation: 1)])
    guard case .terminating = state.phase else {
      Issue.record("execution did not enter cleanup")
      return
    }

    let terminalTransition = try ProviderExecutionReducer.reduce(
      state: state,
      event: .cleanupCompleted
    )
    state = terminalTransition.0
    let terminal = terminalTransition.1
    #expect(terminal == [.publish(.terminal(.completed(completion)))])
    guard case .terminal = state.phase else {
      Issue.record("execution did not become terminal")
      return
    }
    let unchanged = try ProviderExecutionReducer.reduce(state: state, event: .cancelRequested)
    #expect(unchanged.1.isEmpty)
  }

  @Test("Execution commits only on first visible output and can retry before it")
  func executionVisibleOutputCommit() throws {
    let request = try makeRequest()
    let admitted = try ProviderExecutionReducer.reduce(
      state: ProviderExecutionState(),
      event: .requestAdmitted(request)
    )
    let metadata = try ProviderResponseMetadata(
      requestID: request.id,
      providerRequestID: "remote-1",
      providerID: request.selection.providerID,
      modelID: request.selection.modelID,
      startedAt: Date(timeIntervalSince1970: 1)
    )
    let opened = try ProviderExecutionReducer.reduce(
      state: admitted.0,
      event: .transportOpened(metadata)
    )
    let retry = try ProviderExecutionReducer.reduce(
      state: opened.0,
      event: .retryRequested
    )
    #expect(retry.1.isEmpty)
    guard case .opening = retry.0.phase else {
      Issue.record("retry did not restore the opening phase")
      return
    }

    let reopened = try ProviderExecutionReducer.reduce(
      state: retry.0,
      event: .transportOpened(metadata)
    )
    #expect(reopened.1.isEmpty)
    let firstText = try ProviderExecutionReducer.reduce(
      state: reopened.0,
      event: .textDeltaReceived("hello")
    )
    #expect(firstText.1 == [.publish(.textDelta("hello"))])
    let laterText = try ProviderExecutionReducer.reduce(
      state: firstText.0,
      event: .textDeltaReceived(" world")
    )
    #expect(laterText.1 == [.publish(.textDelta(" world"))])
    #expect(throws: ProviderCoreError.self) {
      try ProviderExecutionReducer.reduce(state: firstText.0, event: .retryRequested)
    }
  }

  @Test("Reasoning deltas are separate visible output and prevent retry")
  func executionReasoningDeltaCommit() throws {
    let request = try makeRequest()
    let admitted = try ProviderExecutionReducer.reduce(
      state: ProviderExecutionState(),
      event: .requestAdmitted(request)
    )
    let metadata = try ProviderResponseMetadata(
      requestID: request.id,
      providerRequestID: "remote-1",
      providerID: request.selection.providerID,
      modelID: request.selection.modelID,
      startedAt: Date(timeIntervalSince1970: 1)
    )
    let opened = try ProviderExecutionReducer.reduce(
      state: admitted.0,
      event: .transportOpened(metadata)
    )
    let reasoning = try ProviderExecutionReducer.reduce(
      state: opened.0,
      event: .reasoningDeltaReceived("checking sources")
    )
    #expect(reasoning.1 == [.publish(.reasoningDelta("checking sources"))])
    #expect(throws: ProviderCoreError.self) {
      try ProviderExecutionReducer.reduce(state: reasoning.0, event: .retryRequested)
    }
  }

  @Test("Reasoning events remain public Codable stream values")
  func reasoningDeltaCodableRoundTrip() throws {
    let event = ProviderTurnEvent.reasoningDelta("checking sources")
    #expect(
      try JSONDecoder().decode(ProviderTurnEvent.self, from: JSONEncoder().encode(event)) == event)
  }

  @Test("Bounded stream coalesces adjacent text")
  func boundedStreamCoalescing() async throws {
    let (stream, sink) = ProviderEventStream.make(
      capacity: 4,
      maximumCoalescedTextScalars: 32
    )
    #expect(await sink.send(.textDelta("a")) == .accepted)
    #expect(await sink.send(.textDelta("b")) == .coalesced)
    #expect(await sink.finish(with: .cancelled))

    var iterator = stream.makeAsyncIterator()
    var events: [ProviderTurnEvent] = []
    while let event = await iterator.next() { events.append(event) }
    #expect(events == [.textDelta("ab"), .terminal(.cancelled)])
  }

  @Test("Bounded stream coalesces reasoning without mixing it with text")
  func reasoningDeltaBatching() async throws {
    let (stream, sink) = ProviderEventStream.make(
      capacity: 5,
      maximumCoalescedTextScalars: 32
    )
    #expect(await sink.send(.reasoningDelta("check ")) == .accepted)
    #expect(await sink.send(.reasoningDelta("sources")) == .coalesced)
    #expect(await sink.send(.textDelta("answer")) == .accepted)
    #expect(await sink.send(.reasoningDelta("final check")) == .accepted)
    #expect(await sink.finish(with: .cancelled))

    var iterator = stream.makeAsyncIterator()
    var events: [ProviderTurnEvent] = []
    while let event = await iterator.next() { events.append(event) }
    #expect(
      events == [
        .reasoningDelta("check sources"),
        .textDelta("answer"),
        .reasoningDelta("final check"),
        .terminal(.cancelled),
      ]
    )
  }

  @Test("Token-sized text deltas are batched and joined once at consumption")
  func tokenDeltaBatching() async throws {
    let (stream, sink) = ProviderEventStream.make(
      capacity: 4,
      maximumCoalescedTextScalars: 8_192
    )
    for _ in 0..<4_096 {
      let result = await sink.send(.textDelta("x"))
      #expect(result == .accepted || result == .coalesced)
    }
    #expect(
      await sink.finish(
        with: .completed(try ProviderCompletion(finishedAt: Date(timeIntervalSince1970: 1)))))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .textDelta(String(repeating: "x", count: 4_096)))
    guard case .terminal(.completed) = await iterator.next() else {
      Issue.record("batched stream did not preserve its terminal")
      return
    }
    #expect(await iterator.next() == nil)
  }

  @Test("Overflow is explicit and terminal remains lossless")
  func boundedStreamOverflow() async throws {
    let (stream, sink) = ProviderEventStream.make(
      capacity: 3,
      maximumCoalescedTextScalars: 4
    )
    #expect(await sink.send(.textDelta("aaaa")) == .accepted)
    #expect(await sink.send(.textDelta("bbbb")) == .accepted)
    #expect(await sink.send(.textDelta("overflow")) == .overflow)
    let failure = ProviderFailure(
      code: .consumerBackpressureExceeded,
      message: "bounded overflow"
    )
    #expect(await sink.finish(with: .failed(failure)))

    var iterator = stream.makeAsyncIterator()
    var events: [ProviderTurnEvent] = []
    while let event = await iterator.next() { events.append(event) }
    #expect(events.last == .terminal(.failed(failure)))
  }

  @Test("Reducer generations never wrap")
  func generationOverflow() throws {
    let request = try makeRequest()
    #expect(throws: ProviderCoreError.self) {
      try ProviderExecutionReducer.reduce(
        state: .init(generation: .max, phase: .idle),
        event: .requestAdmitted(request)
      )
    }
    #expect(throws: ProviderCoreError.self) {
      try ProviderAccountReducer.reduce(
        state: .init(generation: .max, phase: .idle),
        event: .registrationRequested(try registration())
      )
    }
  }

  @Test("Security-sensitive URLs, schemes, secrets, and fallback policy fail closed")
  func securityBoundaryValidation() throws {
    let externalAuth = try ProviderCredentialMaterial(externalAuthFilePath: "/private/auth.json")
    #expect(!externalAuth.debugDescription.contains("/private/auth.json"))
    #expect(throws: ProviderCoreError.self) {
      _ = try SensitiveValue("secret\r\ninjected: header")
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderEndpointConfiguration(
        baseURL: try #require(URL(string: "https://api.example.com/base?token=unexpected"))
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderAuthorizationRequest(
        providerID: try ProviderID("provider"),
        authorizationURL: try #require(URL(string: "https://user@example.com/authorize")),
        callbackScheme: "semi",
        state: "state"
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderAuthorizationRequest(
        providerID: try ProviderID("provider"),
        authorizationURL: try #require(URL(string: "https://example.com/authorize")),
        callbackScheme: "1semi",
        state: "state"
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderAuthorizationRequest(
        providerID: try ProviderID("provider"),
        authorizationURL: try #require(URL(string: "https://example.com/authorize")),
        callbackScheme: "semi",
        state: "state\nsmuggled"
      )
    }
    #expect(throws: ProviderCoreError.self) {
      _ = try ProviderRequestConstraints(allowsProviderEndpointFallbacks: true)
    }
  }

  @Test("Turn request round-trips every request policy it publicly exposes")
  func turnRequestRoundTripsEveryPolicy() throws {
    // A policy that survives construction but not serialization is a silent
    // downgrade: `.required` would decode back as `.automatic`.
    let tool = try ProviderToolDefinition(
      name: "lookup",
      description: "looks a value up",
      inputSchema: ["type": "object"]
    )
    let choices: [ProviderToolChoice] = [.automatic, .required, .named("lookup")]
    for choice in choices {
      let request = try ProviderTurnRequest(
        id: ProviderRequestID("request-1"),
        selection: ProviderSelection(
          providerID: BuiltInProviderID.anthropic,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("model-1")
        ),
        messages: [try ProviderMessage(role: .user, text: "hello")],
        tools: [tool],
        toolChoice: choice,
        output: .applicationValidatedJSON(name: "result", schema: ["type": "object"]),
        reasoning: .effort(.high),
        constraints: try ProviderRequestConstraints(maximumOutputTokens: 4_096)
      )
      let decoded = try JSONDecoder().decode(
        ProviderTurnRequest.self,
        from: try JSONEncoder().encode(request)
      )
      #expect(decoded.toolChoice == choice)
      #expect(decoded.output == request.output)
      #expect(decoded.reasoning == request.reasoning)
      #expect(decoded.constraints == request.constraints)
      #expect(decoded == request)
    }

    // A decoded named choice still has to name a supplied tool.
    #expect(throws: ProviderCoreError.self) {
      try JSONDecoder().decode(
        ProviderToolChoice.self,
        from: Data(#"{"type":"named","name":"not a tool name"}"#.utf8)
      )
    }
  }

  @Test("Codable input cannot bypass public value invariants")
  func codableValidation() throws {
    let decoder = JSONDecoder()

    #expect(throws: ProviderCoreError.self) {
      try decoder.decode(
        ProviderEndpointConfiguration.self,
        from: Data(#"{"baseURL":"http://example.com"}"#.utf8)
      )
    }
    #expect(throws: ProviderCoreError.self) {
      try decoder.decode(
        ProviderMessage.self,
        from: Data(#"{"role":"user","content":[]}"#.utf8)
      )
    }
    #expect(throws: ProviderCoreError.self) {
      try decoder.decode(
        ProviderRequestConstraints.self,
        from: Data(
          #"{"dataCollection":"deny","requiresZeroDataRetention":true,"requiresParameterSupport":true,"allowsProviderEndpointFallbacks":false,"timeoutMilliseconds":1,"maximumResponseBytes":1024,"maximumRetryAttempts":1}"#
            .utf8
        )
      )
    }
    #expect(throws: ProviderCoreError.self) {
      try decoder.decode(
        ProviderUsage.self,
        from: Data(#"{"inputTokens":-1}"#.utf8)
      )
    }

    let failure = try decoder.decode(
      ProviderFailure.self,
      from: Data(
        #"{"code":"authentication_failed","message":"Bearer secret-token","providerStatusCode":401}"#
          .utf8
      )
    )
    #expect(failure.message == "Bearer <redacted>")
    #expect(throws: ProviderCoreError.self) {
      try decoder.decode(
        ProviderFailure.self,
        from: Data(
          #"{"code":"server_failed","message":"bad status","providerStatusCode":700}"#.utf8
        )
      )
    }
  }

  @Test("Public event streams reject a second consumer without crashing")
  func multipleStreamConsumersFailExplicitly() async throws {
    let (turnStream, turnSink) = ProviderEventStream.make()
    #expect(await turnSink.send(.textDelta("owned")) == .accepted)
    var firstTurn = turnStream.makeAsyncIterator()
    var secondTurn = turnStream.makeAsyncIterator()
    #expect(await firstTurn.next() == .textDelta("owned"))
    guard case .terminal(.failed(let turnFailure)) = await secondTurn.next() else {
      Issue.record("second turn consumer did not receive an explicit failure")
      return
    }
    #expect(turnFailure.code == .invalidRequest)
    #expect(await secondTurn.next() == nil)
    #expect(await turnSink.finish(with: .cancelled))
    #expect(await firstTurn.next() == .terminal(.cancelled))

    let (accountStream, accountSink) = ProviderAccountEventStream.make()
    #expect(await accountSink.send(.staging))
    var firstAccount = accountStream.makeAsyncIterator()
    var secondAccount = accountStream.makeAsyncIterator()
    #expect(await firstAccount.next() == .staging)
    guard case .failed(let accountFailure) = await secondAccount.next() else {
      Issue.record("second account consumer did not receive an explicit failure")
      return
    }
    #expect(accountFailure.code == .invalidRequest)
    #expect(await secondAccount.next() == nil)
    #expect(await accountSink.send(.failed(ProviderFailure(code: .cancelled, message: "done"))))
    guard case .failed = await firstAccount.next() else {
      Issue.record("primary account consumer lost its terminal")
      return
    }
  }

  @Test("Account stream reserves its terminal slot under backpressure")
  func accountTerminalReservation() async {
    let (stream, sink) = ProviderAccountEventStream.make(capacity: 3)
    #expect(await sink.send(.staging))
    #expect(await sink.send(.verifying))
    #expect(!(await sink.send(.activating)))

    let terminal = ProviderFailure(code: .cancelled, message: "stopped")
    #expect(await sink.send(.failed(terminal)))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .staging)
    #expect(await iterator.next() == .verifying)
    #expect(await iterator.next() == .failed(terminal))
    #expect(await iterator.next() == nil)
  }

  @Test("Inconsistent staged credentials enter compensation instead of leaking")
  func inconsistentStagedCredentialCompensates() throws {
    let request = try registration()
    var state = try ProviderAccountReducer.reduce(
      state: ProviderAccountState(),
      event: .registrationRequested(request)
    ).0
    let inconsistent = ProviderCredentialRecord(
      reference: try ProviderCredentialReference("credential-bad"),
      accountID: request.accountID,
      providerID: request.providerID,
      label: request.label,
      source: .externalAuthFileReference,
      state: .staged,
      endpoint: request.endpoint,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )

    let transition = try ProviderAccountReducer.reduce(
      state: state,
      event: .credentialStaged(inconsistent)
    )
    state = transition.0
    guard case .compensating(_, let record, let failure) = state.phase else {
      Issue.record("inconsistent staged record did not enter compensation")
      return
    }
    #expect(record.reference == inconsistent.reference)
    #expect(failure.code == .internalInvariant)
    #expect(transition.1.count == 1)
    guard case .removeStagedCredential(let removed, _) = transition.1[0] else {
      Issue.record("compensation did not remove the staged credential")
      return
    }
    #expect(removed.reference == inconsistent.reference)
  }

  private func makeRequest() throws -> ProviderTurnRequest {
    try ProviderTurnRequest(
      id: ProviderRequestID("request-1"),
      selection: .init(
        providerID: BuiltInProviderID.openRouter,
        accountID: ProviderAccountID("account-1"),
        modelID: ProviderModelID("vendor/model")
      ),
      messages: [try .init(role: .user, text: "hello")],
      constraints: ProviderRequestConstraints()
    )
  }

  private func registration() throws -> ProviderAccountRegistrationRequest {
    try .init(
      accountID: ProviderAccountID("account-1"),
      providerID: BuiltInProviderID.openRouter,
      label: "OpenRouter",
      credential: .apiKey(SensitiveValue("secret-value"))
    )
  }

  private func credentialRecord(
    request: ProviderAccountRegistrationRequest,
    state: ProviderCredentialRecordState
  ) throws -> ProviderCredentialRecord {
    .init(
      reference: try ProviderCredentialReference("credential-1"),
      accountID: request.accountID,
      providerID: request.providerID,
      label: request.label,
      source: request.credential.source,
      state: state,
      endpoint: request.endpoint,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }
}
