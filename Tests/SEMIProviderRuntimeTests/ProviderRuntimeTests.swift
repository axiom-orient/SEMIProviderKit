import Foundation
import Testing

@testable import SEMIProviderCore
@testable import SEMIProviderRuntime

@Suite("SEMIProviderRuntime")
struct ProviderRuntimeTests {
  @Test("OAuth replay ledger remains bounded and rejects recent state reuse")
  func boundedOAuthReplayWindow() {
    var window = OAuthStateReplayWindow(capacity: 3)
    let first = window.consume("state-1")
    let second = window.consume("state-2")
    let third = window.consume("state-3")
    let duplicate = window.consume("state-2")
    #expect(first)
    #expect(second)
    #expect(third)
    #expect(!duplicate)
    #expect(window.count == 3)
    let fourth = window.consume("state-4")
    #expect(fourth)
    #expect(window.count == 3)
    let evictedCanBeReused = window.consume("state-1")
    #expect(evictedCanBeReused)
  }

  @Test("Built-in registry exposes exactly the supported provider set")
  func registry() throws {
    let descriptors = BuiltInProviderRegistry().descriptors()
    #expect(descriptors.count == 10)
    #expect(
      Set(descriptors.map(\.id))
        == Set([
          BuiltInProviderID.codex,
          BuiltInProviderID.openAI,
          BuiltInProviderID.anthropic,
          BuiltInProviderID.gemini,
          BuiltInProviderID.openRouter,
          BuiltInProviderID.deepSeek,
          BuiltInProviderID.qwen,
          BuiltInProviderID.kimi,
          BuiltInProviderID.zai,
          BuiltInProviderID.miniMax,
        ]))
    let codex = try #require(descriptors.first { $0.id == BuiltInProviderID.codex })
    #expect(codex.displayName == "Codex (ChatGPT subscription)")
    #expect(codex.protocolFamily == .codexResponses)
  }

  @Test("Public in-memory credential store provides an ephemeral account lifecycle")
  func inMemoryCredentialStoreLifecycle() async throws {
    let store = InMemoryProviderCredentialStore()
    let accountID = try ProviderAccountID("ephemeral-account")
    let request = try ProviderAccountRegistrationRequest(
      accountID: accountID,
      providerID: BuiltInProviderID.openAI,
      label: "Ephemeral OpenAI",
      credential: .apiKey(try SensitiveValue("secret-key"))
    )
    let staged = try await store.stage(request, at: Date(timeIntervalSince1970: 1))
    #expect(staged.state == .staged)
    #expect(await store.record(accountID: accountID) == staged)

    await expectThrownProviderFailure {
      _ = try await store.stage(request, at: Date(timeIntervalSince1970: 2))
    }

    try await store.activate(staged, at: Date(timeIntervalSince1970: 2))
    let lease = try await store.lease(accountID: accountID)
    #expect(lease.record.state == .active)
    #expect(lease.record.reference == staged.reference)
    #expect(lease.material == request.credential)

    // Registration compensation holds the staged snapshot, so removal must
    // still succeed after activation when the identity is unchanged.
    try await store.remove(staged)
    #expect(await store.records().isEmpty)

    let restaged = try await store.stage(request, at: Date(timeIntervalSince1970: 3))
    #expect(restaged.reference != staged.reference)
    try await store.remove(restaged)
  }

  @Test("SSE decoder handles fragmentation, CRLF, multiline data, and finish")
  func sseDecoder() throws {
    var decoder = ServerSentEventDecoder(maximumLineBytes: 256, maximumEventBytes: 1_024)
    #expect(try decoder.feed(Data("event: note\r\ndata: first".utf8)).isEmpty)
    let events = try decoder.feed(Data("\r\ndata: second\r\nid: 7\r\nretry: 50\r\n\r\n".utf8))
    #expect(
      events == [
        ServerSentEvent(event: "note", data: "first\nsecond", id: "7", retryMilliseconds: 50)
      ])
    #expect(try decoder.finish().isEmpty)
  }

  @Test("SSE fragmented lines are scanned once and all line endings are accepted")
  func sseIncrementalScan() throws {
    var decoder = ServerSentEventDecoder(maximumLineBytes: 8_192, maximumEventBytes: 16_384)
    let payload =
      Data([0xEF, 0xBB, 0xBF])
      + Data(("data: " + String(repeating: "x", count: 4_096) + "\r\r").utf8)
    var events: [ServerSentEvent] = []
    for byte in payload {
      events.append(contentsOf: try decoder.feed(Data([byte])))
    }
    #expect(
      events == [
        ServerSentEvent(
          event: nil,
          data: String(repeating: "x", count: 4_096),
          id: nil,
          retryMilliseconds: nil
        )
      ])
    #expect(decoder.scannedByteCount == payload.count)

    var mixed = ServerSentEventDecoder(maximumLineBytes: 64, maximumEventBytes: 256)
    let mixedEvents = try mixed.feed(Data("data: one\r\ndata: two\ndata: three\r\r".utf8))
    #expect(
      mixedEvents == [
        ServerSentEvent(event: nil, data: "one\ntwo\nthree", id: nil, retryMilliseconds: nil)
      ])
  }

  @Test("SSE decoder rejects oversized and malformed UTF-8 input")
  func sseBounds() throws {
    var oversized = ServerSentEventDecoder(maximumLineBytes: 4, maximumEventBytes: 8)
    #expect(throws: ProviderFailure.self) {
      try oversized.feed(Data("data: too-long\n".utf8))
    }

    var invalid = ServerSentEventDecoder(maximumLineBytes: 32, maximumEventBytes: 64)
    #expect(throws: ProviderFailure.self) {
      try invalid.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0x0A]))
    }
  }

  @Test("Codex external credentials reject header injection at the file boundary")
  func codexCredentialHeaderInjection() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("providerkit-codex-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = directory.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"token\r\nInjected: value","account_id":"account"}}"#.utf8)
      .write(to: auth)

    let request = try makeRequest(providerID: BuiltInProviderID.codex)
    let record = ProviderCredentialRecord(
      reference: try ProviderCredentialReference("codex-ref"),
      accountID: request.selection.accountID,
      providerID: BuiltInProviderID.codex,
      label: "Codex",
      source: .externalAuthFileReference,
      state: .active,
      endpoint: nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let lease = ProviderCredentialLease(
      record: record,
      material: try ProviderCredentialMaterial(externalAuthFilePath: auth.path)
    )
    await expectThrownProviderFailure {
      _ = try await OpenAIResponsesAdapter(kind: .codex).makeExecutionRequest(
        request, credential: lease)
    }
  }

  @Test("Codex client version is declared and does not inspect the host")
  func codexClientVersionResolution() {
    #expect(CodexClientVersion.resolve() == "0.144.1")
  }

  @Test("Secure credential reader binds validation and read to one file descriptor")
  func secureCredentialReader() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("providerkit-secure-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let regular = directory.appendingPathComponent("auth.json")
    let payload = Data(#"{"tokens":{"access_token":"token","account_id":"account"}}"#.utf8)
    try payload.write(to: regular)
    #expect(try SecureRegularFileReader.read(regular, maximumBytes: payload.count) == payload)

    let symlink = directory.appendingPathComponent("auth-link.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
    #expect(throws: ProviderFailure.self) {
      try SecureRegularFileReader.read(symlink, maximumBytes: payload.count)
    }

    #expect(throws: ProviderFailure.self) {
      try SecureRegularFileReader.read(regular, maximumBytes: payload.count - 1)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: regular.path)
    #expect(throws: ProviderFailure.self) {
      try SecureRegularFileReader.read(regular, maximumBytes: payload.count)
    }
  }

  @Test("Tool history preserves the assistant call before the tool result")
  func toolHistoryEncoding() async throws {
    let tool = try ProviderToolDefinition(
      name: "lookup_weather",
      description: "looks up weather",
      inputSchema: ["type": "object"]
    )
    let messages = [
      try ProviderMessage(role: .user, text: "weather in Seoul"),
      try ProviderMessage(
        role: .assistant,
        content: [.toolCall(callID: "call-1", name: "lookup_weather", arguments: ["city": "Seoul"])]
      ),
      try ProviderMessage(
        role: .tool,
        content: [.toolResult(callID: "call-1", name: "lookup_weather", value: ["temperature": 22])]
      ),
    ]
    func request(_ providerID: ProviderID) throws -> ProviderTurnRequest {
      try ProviderTurnRequest(
        id: ProviderRequestID("tool-history"),
        selection: ProviderSelection(
          providerID: providerID,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("vendor/model")
        ),
        messages: messages,
        tools: [tool],
        constraints: ProviderRequestConstraints()
      )
    }

    let responses = try await encodedBody(
      OpenAIResponsesAdapter(kind: .openAI), request: request(BuiltInProviderID.openAI)
    )
    let responseInput = try #require(responses["input"]?.arrayValue)
    #expect(responseInput.contains { $0["type"]?.stringValue == "function_call" })
    #expect(responseInput.contains { $0["type"]?.stringValue == "function_call_output" })

    let anthropic = try await encodedBody(
      AnthropicMessagesAdapter(kind: .anthropic), request: request(BuiltInProviderID.anthropic)
    )
    let anthropicMessages = try #require(anthropic["messages"]?.arrayValue)
    #expect(
      anthropicMessages.contains {
        $0["content"]?.arrayValue?.contains { $0["type"]?.stringValue == "tool_use" } == true
      })
    #expect(
      anthropicMessages.contains {
        $0["content"]?.arrayValue?.contains { $0["type"]?.stringValue == "tool_result" } == true
      })

    let chat = try await encodedBody(
      OpenAIChatAdapter(kind: .openRouter), request: request(BuiltInProviderID.openRouter)
    )
    let chatMessages = try #require(chat["messages"]?.arrayValue)
    #expect(
      chatMessages.contains {
        $0["tool_calls"]?.arrayValue?.first?["id"]?.stringValue == "call-1"
      })
    #expect(chatMessages.contains { $0["tool_call_id"]?.stringValue == "call-1" })

    await expectCapabilityMismatch {
      _ = try await encodedBody(
        GeminiInteractionsAdapter(),
        request: request(BuiltInProviderID.gemini)
      )
    }
  }

  @Test("Failed tool results use each dialect's qualified wire field")
  func failedToolResultEncoding() async throws {
    let tool = try ProviderToolDefinition(
      name: "lookup_weather",
      description: "looks up weather",
      inputSchema: ["type": "object"]
    )
    let failedResult = ProviderMessageContent.toolResult(
      callID: "call-1",
      name: "lookup_weather",
      value: ["message": "service unavailable"],
      isError: true
    )
    let messages = [
      try ProviderMessage(role: .user, text: "weather in Seoul"),
      try ProviderMessage(
        role: .assistant,
        content: [.toolCall(callID: "call-1", name: "lookup_weather", arguments: ["city": "Seoul"])]
      ),
      try ProviderMessage(role: .tool, content: [failedResult]),
    ]
    func request(_ providerID: ProviderID) throws -> ProviderTurnRequest {
      try ProviderTurnRequest(
        id: ProviderRequestID("failed-tool-history"),
        selection: ProviderSelection(
          providerID: providerID,
          accountID: ProviderAccountID("account-1"),
          modelID: ProviderModelID("vendor/model")
        ),
        messages: messages,
        tools: [tool],
        constraints: ProviderRequestConstraints()
      )
    }

    let anthropic = try await encodedBody(
      AnthropicMessagesAdapter(kind: .anthropic), request: request(BuiltInProviderID.anthropic)
    )
    let anthropicResult = try #require(
      anthropic["messages"]?.arrayValue?.flatMap { $0["content"]?.arrayValue ?? [] }
        .first { $0["type"]?.stringValue == "tool_result" }
    )
    #expect(anthropicResult["is_error"]?.boolValue == true)

    let miniMax = try await encodedBody(
      AnthropicMessagesAdapter(kind: .miniMax), request: request(BuiltInProviderID.miniMax)
    )
    let miniMaxResult = try #require(
      miniMax["messages"]?.arrayValue?.flatMap { $0["content"]?.arrayValue ?? [] }
        .first { $0["type"]?.stringValue == "tool_result" }
    )
    #expect(miniMaxResult["content"]?.stringValue?.contains("service unavailable") == true)
    #expect(miniMaxResult["is_error"] == nil)
    #expect(!String(decoding: try miniMax.encodedData(), as: UTF8.self).contains("\"is_error\""))

    let responses = try await encodedBody(
      OpenAIResponsesAdapter(kind: .openAI), request: request(BuiltInProviderID.openAI)
    )
    let responseOutput = try #require(
      responses["input"]?.arrayValue?.first { $0["type"]?.stringValue == "function_call_output" }
    )
    #expect(responseOutput["output"]?.stringValue?.contains("service unavailable") == true)
    #expect(responseOutput["is_error"] == nil)

    let chat = try await encodedBody(
      OpenAIChatAdapter(kind: .openRouter), request: request(BuiltInProviderID.openRouter)
    )
    let chatResult = try #require(
      chat["messages"]?.arrayValue?.first { $0["tool_call_id"]?.stringValue == "call-1" }
    )
    #expect(chatResult["content"]?.stringValue?.contains("service unavailable") == true)
    #expect(chatResult["is_error"] == nil)

    let geminiContinuation = try ProviderContinuation(
      providerID: BuiltInProviderID.gemini,
      accountID: ProviderAccountID("account-1"),
      value: "interaction-1"
    )
    let geminiConstraints = try ProviderRequestConstraints(
      dataCollection: .allow,
      requiresZeroDataRetention: false
    )
    let geminiRequest = try ProviderTurnRequest(
      id: ProviderRequestID("failed-tool-gemini-history"),
      selection: ProviderSelection(
        providerID: BuiltInProviderID.gemini,
        accountID: ProviderAccountID("account-1"),
        modelID: ProviderModelID("vendor/model")
      ),
      messages: [
        try ProviderMessage(role: .user, text: "weather in Seoul"),
        try ProviderMessage(role: .tool, content: [failedResult]),
      ],
      tools: [tool],
      continuation: geminiContinuation,
      constraints: geminiConstraints
    )
    let gemini = try await encodedBody(
      GeminiInteractionsAdapter(), request: geminiRequest
    )
    #expect(gemini["previous_interaction_id"]?.stringValue == "interaction-1")
    let geminiResult = try #require(
      gemini["input"]?.arrayValue?.first { $0["type"]?.stringValue == "function_result" }
    )
    let geminiResultContent = geminiResult.value(at: "result", "content")?.arrayValue
    #expect(
      geminiResultContent?.contains {
        $0["text"]?.stringValue?.contains("service unavailable") == true
      } == true
    )
    #expect(geminiResult["is_error"]?.boolValue == true)
    #expect(String(decoding: try gemini.encodedData(), as: UTF8.self).contains("\"is_error\""))
  }

  @Test("Runtime rejects a provider tool call that was not declared")
  func runtimeRejectsUndeclaredProviderTool() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"unsafe-tool","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"delete_everything","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      )
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let tool = try ProviderToolDefinition(
      name: "lookup_weather",
      description: "looks up weather",
      inputSchema: ["type": "object"]
    )
    let request = try ProviderTurnRequest(
      id: ProviderRequestID("undeclared-tool"),
      selection: ProviderSelection(
        providerID: BuiltInProviderID.openRouter,
        accountID: account,
        modelID: ProviderModelID("vendor/model")
      ),
      messages: [try ProviderMessage(role: .user, text: "weather")],
      tools: [tool],
      constraints: ProviderRequestConstraints()
    )
    var terminal: ProviderTerminal?
    for await event in await runtime.execute(request) {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("undeclared provider tool was not rejected")
      return
    }
    #expect(failure.code == .malformedResponse)
    await runtime.shutdown()
  }

  @Test("OpenRouter request is direct, private by default, and does not fallback")
  func openRouterEncoding() async throws {
    let adapter = OpenAIChatAdapter(kind: .openRouter)
    let request = try makeRequest(providerID: BuiltInProviderID.openRouter)
    let wire = try await adapter.makeExecutionRequest(request, credential: try lease(for: request))
    #expect(wire.urlRequest.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(wire.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    let body = try #require(wire.urlRequest.httpBody)
    let json = try ProviderJSONValue.decode(from: body)
    #expect(json.value(at: "provider", "allow_fallbacks")?.boolValue == false)
    #expect(json.value(at: "provider", "require_parameters")?.boolValue == true)
    #expect(json.value(at: "provider", "data_collection")?.stringValue == "deny")
    #expect(json.value(at: "provider", "zdr")?.boolValue == true)
    #expect(json.value(at: "stream_options", "include_usage")?.boolValue == true)
  }

  @Test("Application-validated JSON uses the strongest qualified provider constraint")
  func applicationValidatedJSONEncoding() async throws {
    let schema: ProviderJSONValue = [
      "type": "object",
      "properties": ["value": ["type": "string"]],
      "required": ["value"],
      "additionalProperties": false,
    ]
    let output = ProviderOutputRequirement.applicationValidatedJSON(
      name: "asa_plan",
      schema: schema
    )

    let openAIRequest = try makeRequest(providerID: BuiltInProviderID.openAI, output: output)
    let openAIWire = try await OpenAIResponsesAdapter(kind: .openAI).makeExecutionRequest(
      openAIRequest,
      credential: try lease(for: openAIRequest)
    )
    let openAIRoot = try ProviderJSONValue.decode(
      from: try #require(openAIWire.urlRequest.httpBody))
    #expect(openAIRoot.value(at: "text", "format", "type")?.stringValue == "json_schema")
    #expect(openAIRoot.value(at: "text", "format", "schema") == schema)

    let geminiRequest = try makeRequest(providerID: BuiltInProviderID.gemini, output: output)
    let geminiWire = try await GeminiInteractionsAdapter().makeExecutionRequest(
      geminiRequest,
      credential: try lease(for: geminiRequest)
    )
    let geminiRoot = try ProviderJSONValue.decode(
      from: try #require(geminiWire.urlRequest.httpBody))
    #expect(geminiRoot.value(at: "response_format", "mime_type")?.stringValue == "application/json")
    #expect(geminiRoot.value(at: "response_format", "schema") == schema)

    for (providerID, kind) in [
      (BuiltInProviderID.openRouter, OpenAIChatAdapter.Kind.openRouter),
      (BuiltInProviderID.kimi, .kimi),
    ] {
      let request = try makeRequest(providerID: providerID, output: output)
      let wire = try await OpenAIChatAdapter(kind: kind).makeExecutionRequest(
        request,
        credential: try lease(for: request)
      )
      let root = try ProviderJSONValue.decode(from: try #require(wire.urlRequest.httpBody))
      #expect(root.value(at: "response_format", "type")?.stringValue == "json_schema")
      #expect(root.value(at: "response_format", "json_schema", "schema") == schema)
    }

    for (providerID, kind) in [(BuiltInProviderID.deepSeek, OpenAIChatAdapter.Kind.deepSeek)] {
      let request = try makeRequest(providerID: providerID, output: output)
      let wire = try await OpenAIChatAdapter(kind: kind).makeExecutionRequest(
        request,
        credential: try lease(for: request)
      )
      let root = try ProviderJSONValue.decode(from: try #require(wire.urlRequest.httpBody))
      #expect(root.value(at: "response_format", "type")?.stringValue == "json_object")
      #expect(
        root["messages"]?.arrayValue?.first?.value(at: "content")?.stringValue?.contains(
          "JSON object") == true)
    }

    let zaiRequest = try makeRequest(providerID: BuiltInProviderID.zai, output: output)
    let zaiWire = try await AnthropicMessagesAdapter(kind: .zai).makeExecutionRequest(
      zaiRequest,
      credential: try lease(for: zaiRequest)
    )
    #expect(zaiWire.urlRequest.url?.absoluteString == "https://api.z.ai/api/anthropic/v1/messages")
    #expect(zaiWire.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    let zaiRoot = try ProviderJSONValue.decode(from: try #require(zaiWire.urlRequest.httpBody))
    #expect(zaiRoot["output_config"] == nil)

    let qwenRequest = try makeRequest(providerID: BuiltInProviderID.qwen, output: output)
    let qwenEndpoint = try ProviderEndpointConfiguration(
      baseURL: try #require(URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1"))
    )
    let qwenWire = try await OpenAIChatAdapter(kind: .qwen).makeExecutionRequest(
      qwenRequest,
      credential: try lease(for: qwenRequest, endpoint: qwenEndpoint)
    )
    let qwenRoot = try ProviderJSONValue.decode(from: try #require(qwenWire.urlRequest.httpBody))
    #expect(qwenRoot.value(at: "response_format", "type")?.stringValue == "json_object")

    let anthropicRequest = try makeRequest(
      providerID: BuiltInProviderID.anthropic,
      output: output
    )
    let anthropicWire = try await AnthropicMessagesAdapter(kind: .anthropic).makeExecutionRequest(
      anthropicRequest,
      credential: try lease(for: anthropicRequest)
    )
    let anthropicRoot = try ProviderJSONValue.decode(
      from: try #require(anthropicWire.urlRequest.httpBody)
    )
    #expect(
      anthropicRoot.value(at: "output_config", "format", "type")?.stringValue == "json_schema")
    #expect(anthropicRoot.value(at: "output_config", "format", "schema") == schema)

    let miniMaxRequest = try makeRequest(
      providerID: BuiltInProviderID.miniMax,
      output: output
    )
    let miniMaxWire = try await AnthropicMessagesAdapter(kind: .miniMax).makeExecutionRequest(
      miniMaxRequest,
      credential: try lease(for: miniMaxRequest)
    )
    let miniMaxRoot = try ProviderJSONValue.decode(
      from: try #require(miniMaxWire.urlRequest.httpBody)
    )
    #expect(miniMaxRoot["output_config"] == nil)
  }

  @Test("Explicit tool choice is encoded and never silently downgraded")
  func explicitToolChoiceEncoding() async throws {
    let tool = try ProviderToolDefinition(
      name: "submit_result",
      description: "Submit one result.",
      inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]
    )
    let named = try makeRequest(
      providerID: BuiltInProviderID.openAI,
      tools: [tool],
      toolChoice: .named("submit_result")
    )
    #expect(
      try await encodedBody(OpenAIResponsesAdapter(kind: .openAI), request: named)
        .value(at: "tool_choice", "name")?.stringValue == "submit_result"
    )

    let required = try makeRequest(
      providerID: BuiltInProviderID.anthropic,
      tools: [tool],
      toolChoice: .required
    )
    #expect(
      try await encodedBody(AnthropicMessagesAdapter(kind: .anthropic), request: required)
        .value(at: "tool_choice", "type")?.stringValue == "any"
    )

    let gemini = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      tools: [tool],
      toolChoice: .required
    )
    await expectThrownProviderFailure {
      _ = try await GeminiInteractionsAdapter().makeExecutionRequest(
        gemini,
        credential: try lease(for: gemini)
      )
    }
  }

  @Test("Output-token limits map to each provider wire dialect")
  func outputTokenLimitEncoding() async throws {
    let constraints = try ProviderRequestConstraints(maximumOutputTokens: 12_345)

    let codexRequest = try makeRequest(
      providerID: BuiltInProviderID.codex,
      constraints: constraints
    )
    await expectCapabilityMismatch {
      _ = try await OpenAIResponsesAdapter(kind: .codex).makeExecutionRequest(
        codexRequest,
        credential: activeLease(
          accountID: codexRequest.selection.accountID,
          providerID: BuiltInProviderID.codex
        )
      )
    }

    let responsesRequest = try makeRequest(
      providerID: BuiltInProviderID.openAI,
      constraints: constraints
    )
    let responsesWire = try await OpenAIResponsesAdapter(kind: .openAI).makeExecutionRequest(
      responsesRequest,
      credential: activeLease(
        accountID: responsesRequest.selection.accountID,
        providerID: BuiltInProviderID.openAI
      )
    )
    let responsesBody = try #require(responsesWire.urlRequest.httpBody)
    #expect(
      try ProviderJSONValue.decode(from: responsesBody)["max_output_tokens"]?.integerValue
        == 12_345
    )

    let chatRequest = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      constraints: constraints
    )
    let chatWire = try await OpenAIChatAdapter(kind: .openRouter).makeExecutionRequest(
      chatRequest,
      credential: activeLease(
        accountID: chatRequest.selection.accountID,
        providerID: BuiltInProviderID.openRouter
      )
    )
    let chatBody = try #require(chatWire.urlRequest.httpBody)
    #expect(
      try ProviderJSONValue.decode(from: chatBody)["max_completion_tokens"]?.integerValue
        == 12_345
    )

    let messagesRequest = try makeRequest(
      providerID: BuiltInProviderID.anthropic,
      constraints: constraints
    )
    let messagesWire = try await AnthropicMessagesAdapter(kind: .anthropic).makeExecutionRequest(
      messagesRequest,
      credential: activeLease(
        accountID: messagesRequest.selection.accountID,
        providerID: BuiltInProviderID.anthropic
      )
    )
    let messagesBody = try #require(messagesWire.urlRequest.httpBody)
    #expect(try ProviderJSONValue.decode(from: messagesBody)["max_tokens"]?.integerValue == 12_345)

    let geminiRequest = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      constraints: constraints
    )
    let geminiWire = try await GeminiInteractionsAdapter().makeExecutionRequest(
      geminiRequest,
      credential: activeLease(
        accountID: geminiRequest.selection.accountID,
        providerID: BuiltInProviderID.gemini
      )
    )
    let geminiBody = try #require(geminiWire.urlRequest.httpBody)
    #expect(
      try ProviderJSONValue.decode(from: geminiBody)
        .value(at: "generation_config", "max_output_tokens")?.integerValue == 12_345
    )
  }

  @Test("Codex repeated turns use caller-owned history without a continuation")
  func codexRepeatedTurnHistory() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("providerkit-codex-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = directory.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"token","account_id":"account"}}"#.utf8).write(to: auth)

    let accountID = try ProviderAccountID("conversation-account")
    let request = try ProviderTurnRequest(
      id: ProviderRequestID("conversation-turn-2"),
      selection: ProviderSelection(
        providerID: BuiltInProviderID.codex,
        accountID: accountID,
        modelID: ProviderModelID("gpt-5.6-luna")
      ),
      messages: [
        try ProviderMessage(role: .developer, text: "Answer concisely."),
        try ProviderMessage(role: .user, text: "Remember luna-memory-4831."),
        try ProviderMessage(role: .assistant, text: "luna-memory-4831"),
        try ProviderMessage(role: .user, text: "What token did you remember?"),
      ],
      constraints: ProviderRequestConstraints()
    )
    let credential = ProviderCredentialLease(
      record: ProviderCredentialRecord(
        reference: try ProviderCredentialReference("codex-history-ref"),
        accountID: accountID,
        providerID: BuiltInProviderID.codex,
        label: "Codex",
        source: .externalAuthFileReference,
        state: .active,
        endpoint: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      ),
      material: try ProviderCredentialMaterial(externalAuthFilePath: auth.path)
    )

    let wire = try await OpenAIResponsesAdapter(kind: .codex).makeExecutionRequest(
      request,
      credential: credential
    )
    let body = try ProviderJSONValue.decode(from: try #require(wire.urlRequest.httpBody))
    let input = try #require(body["input"]?.arrayValue)
    #expect(body["instructions"]?.stringValue == "Answer concisely.")
    #expect(body["previous_response_id"] == nil)
    #expect(input.count == 3)
    #expect(input[0]["role"]?.stringValue == "user")
    #expect(input[1]["role"]?.stringValue == "assistant")
    #expect(input[2]["role"]?.stringValue == "user")

    let noInstructionsRequest = try makeRequest(
      providerID: BuiltInProviderID.codex,
      accountID: accountID,
      requestID: "conversation-turn-3"
    )
    let noInstructionsWire = try await OpenAIResponsesAdapter(kind: .codex).makeExecutionRequest(
      noInstructionsRequest,
      credential: credential
    )
    let noInstructionsBody = try ProviderJSONValue.decode(
      from: try #require(noInstructionsWire.urlRequest.httpBody)
    )
    #expect(noInstructionsBody["instructions"] == nil)
  }

  @Test("Responses rejects a tool event without a stable item identity")
  func responsesToolIdentityIsRequired() throws {
    let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.openAI)
    )
    #expect(throws: ProviderFailure.self) {
      _ = try decoder.consume(
        .init(
          event: "response.output_item.added",
          data:
            #"{"type":"response.output_item.added","item":{"type":"function_call","name":"lookup"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      )
    }
  }

  @Test("Responses never substitutes an item ID for a tool call ID")
  func responsesItemIDIsNotAToolCallID() throws {
    let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.openAI)
    )
    _ = try decoder.consume(
      .init(
        event: "response.output_item.added",
        data:
          #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item-1","name":"lookup"}}"#,
        id: nil,
        retryMilliseconds: nil
      )
    )
    #expect(throws: ProviderFailure.self) {
      _ = try decoder.consume(
        .init(
          event: "response.function_call_arguments.done",
          data:
            #"{"type":"response.function_call_arguments.done","item_id":"item-1","arguments":"{}"}"#,
          id: nil,
          retryMilliseconds: nil
        )
      )
    }
  }

  @Test("Responses bounds the number of active tool states")
  func responsesToolStateIsBounded() throws {
    let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.openAI)
    )
    for index in 0..<ProviderTurnRequest.maximumTools {
      _ = try decoder.consume(
        .init(
          event: "response.output_item.added",
          data:
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item-\#(index)","call_id":"call-\#(index)","name":"lookup"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      )
    }
    #expect(throws: ProviderFailure.self) {
      _ = try decoder.consume(
        .init(
          event: "response.output_item.added",
          data:
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item-overflow","call_id":"call-overflow","name":"lookup"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      )
    }
  }

  @Test("Reasoning policy is either encoded on the wire or rejected, never dropped")
  func reasoningPolicyEncoding() async throws {
    // `.automatic` means "use the provider default", so no dialect may force a
    // reasoning mode that would reject models without extended thinking.
    let anthropicAutomatic = try await encodedBody(
      OpenAIChatAdapter(kind: .openRouter),
      request: makeRequest(providerID: BuiltInProviderID.openRouter, reasoning: .automatic)
    )
    #expect(anthropicAutomatic["reasoning"] == nil)
    let messagesAutomatic = try await encodedBody(
      AnthropicMessagesAdapter(kind: .anthropic),
      request: makeRequest(providerID: BuiltInProviderID.anthropic, reasoning: .automatic)
    )
    #expect(messagesAutomatic["thinking"] == nil)

    // `.disabled` is encoded wherever the provider documents an off switch.
    let messagesDisabled = try await encodedBody(
      AnthropicMessagesAdapter(kind: .anthropic),
      request: makeRequest(providerID: BuiltInProviderID.anthropic, reasoning: .disabled)
    )
    #expect(messagesDisabled.value(at: "thinking", "type")?.stringValue == "disabled")

    let chatDisabled = try await encodedBody(
      OpenAIChatAdapter(kind: .openRouter),
      request: makeRequest(providerID: BuiltInProviderID.openRouter, reasoning: .disabled)
    )
    #expect(chatDisabled.value(at: "reasoning", "enabled")?.boolValue == false)

    let geminiDisabled = try await encodedBody(
      GeminiInteractionsAdapter(),
      request: makeRequest(providerID: BuiltInProviderID.gemini, reasoning: .disabled)
    )
    #expect(
      geminiDisabled.value(at: "generation_config", "thinking_level")?.stringValue == "minimal")

    let messagesEffort = try await encodedBody(
      AnthropicMessagesAdapter(kind: .anthropic),
      request: makeRequest(providerID: BuiltInProviderID.anthropic, reasoning: .effort(.high))
    )
    #expect(messagesEffort.value(at: "thinking", "type")?.stringValue == "adaptive")
    #expect(messagesEffort.value(at: "output_config", "effort")?.stringValue == "high")

    let geminiAutomatic = try await encodedBody(
      GeminiInteractionsAdapter(),
      request: makeRequest(providerID: BuiltInProviderID.gemini, reasoning: .automatic)
    )
    #expect(geminiAutomatic.value(at: "generation_config", "thinking_summaries") == nil)

    let geminiEffort = try await encodedBody(
      GeminiInteractionsAdapter(),
      request: makeRequest(providerID: BuiltInProviderID.gemini, reasoning: .effort(.high))
    )
    #expect(
      geminiEffort.value(at: "generation_config", "thinking_level")?.stringValue == "high")
    #expect(
      geminiEffort.value(at: "generation_config", "thinking_summaries")?.stringValue == "auto")

    // Unqualified dialects fail closed instead of silently ignoring the policy.
    await expectCapabilityMismatch {
      _ = try await encodedBody(
        OpenAIResponsesAdapter(kind: .openAI),
        request: makeRequest(providerID: BuiltInProviderID.openAI, reasoning: .disabled)
      )
    }
    let deepSeekDisabled = try await encodedBody(
      OpenAIChatAdapter(kind: .deepSeek),
      request: makeRequest(providerID: BuiltInProviderID.deepSeek, reasoning: .disabled)
    )
    #expect(deepSeekDisabled.value(at: "thinking", "type")?.stringValue == "disabled")
    await expectCapabilityMismatch {
      _ = try await encodedBody(
        AnthropicMessagesAdapter(kind: .miniMax),
        request: makeRequest(providerID: BuiltInProviderID.miniMax, reasoning: .disabled)
      )
    }
  }

  @Test("Native schema output is emitted only by qualified dialects")
  func nativeSchemaQualification() async throws {
    let output = ProviderOutputRequirement.jsonSchema(
      name: "answer",
      schema: [
        "type": "object",
        "properties": ["value": ["type": "string"]],
        "required": ["value"],
        "additionalProperties": false,
      ],
      strict: true
    )
    let anthropicRequest = try makeRequest(providerID: BuiltInProviderID.anthropic, output: output)
    let anthropicWire = try await AnthropicMessagesAdapter(kind: .anthropic).makeExecutionRequest(
      anthropicRequest,
      credential: try lease(for: anthropicRequest)
    )
    let anthropicRoot = try ProviderJSONValue.decode(
      from: try #require(anthropicWire.urlRequest.httpBody)
    )
    #expect(
      anthropicRoot.value(at: "output_config", "format", "type")?.stringValue == "json_schema")

    let kimiRequest = try makeRequest(providerID: BuiltInProviderID.kimi, output: output)
    let kimiWire = try await OpenAIChatAdapter(kind: .kimi).makeExecutionRequest(
      kimiRequest,
      credential: try lease(for: kimiRequest)
    )
    let kimiRoot = try ProviderJSONValue.decode(from: try #require(kimiWire.urlRequest.httpBody))
    #expect(kimiRoot.value(at: "response_format", "type")?.stringValue == "json_schema")

    let deepSeekRequest = try makeRequest(providerID: BuiltInProviderID.deepSeek, output: output)
    await expectThrownProviderFailure {
      _ = try await OpenAIChatAdapter(kind: .deepSeek).makeExecutionRequest(
        deepSeekRequest,
        credential: try lease(for: deepSeekRequest)
      )
    }

    let miniMaxRequest = try makeRequest(providerID: BuiltInProviderID.miniMax, output: output)
    await expectThrownProviderFailure {
      _ = try await AnthropicMessagesAdapter(kind: .miniMax).makeExecutionRequest(
        miniMaxRequest,
        credential: try lease(for: miniMaxRequest)
      )
    }
  }

  @Test("Qwen requires an explicit regional endpoint")
  func qwenEndpoint() async throws {
    let request = try makeRequest(providerID: BuiltInProviderID.qwen)
    await expectThrownProviderFailure {
      _ = try await OpenAIChatAdapter(kind: .qwen).makeExecutionRequest(
        request,
        credential: try lease(for: request)
      )
    }
  }

  @Test("Gemini request uses current step-based Interactions contract")
  func geminiEncoding() async throws {
    let tool = try ProviderToolDefinition(
      name: "lookup",
      description: "Lookup a value",
      inputSchema: ["type": "object", "properties": ["id": ["type": "string"]]]
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      tools: [tool],
      output: .jsonSchema(
        name: "answer",
        schema: ["type": "object", "properties": ["value": ["type": "string"]]],
        strict: true
      )
    )
    let wire = try await GeminiInteractionsAdapter().makeExecutionRequest(
      request,
      credential: try lease(for: request)
    )
    #expect(
      wire.urlRequest.url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")
    #expect(wire.urlRequest.value(forHTTPHeaderField: "Api-Revision") == nil)
    let root = try ProviderJSONValue.decode(from: try #require(wire.urlRequest.httpBody))
    #expect(root["store"]?.boolValue == false)
    #expect(root["stream"]?.boolValue == true)
    #expect(root["tool_choice"]?.stringValue == "auto")
    #expect(root.value(at: "response_format", "mime_type")?.stringValue == "application/json")
  }

  @Test("Server-side continuations require an explicit retention opt-in")
  func serverSideContinuationRetention() async throws {
    let continuation = try ProviderContinuation(
      providerID: BuiltInProviderID.gemini,
      accountID: ProviderAccountID("account-1"),
      value: "interaction-1"
    )
    let defaultRequest = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      continuation: continuation
    )
    await expectCapabilityMismatch {
      _ = try await encodedBody(
        GeminiInteractionsAdapter(),
        request: defaultRequest
      )
    }

    let optInConstraints = try ProviderRequestConstraints(
      dataCollection: .allow,
      requiresZeroDataRetention: false
    )
    let optedInRequest = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      continuation: continuation,
      constraints: optInConstraints
    )
    let initialGeminiRequest = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      constraints: optInConstraints
    )
    let initialGeminiBody = try await encodedBody(
      GeminiInteractionsAdapter(),
      request: initialGeminiRequest
    )
    #expect(initialGeminiBody["store"]?.boolValue == true)
    let geminiBody = try await encodedBody(
      GeminiInteractionsAdapter(),
      request: optedInRequest
    )
    #expect(geminiBody["store"]?.boolValue == true)
    #expect(geminiBody["previous_interaction_id"]?.stringValue == "interaction-1")

    let openAIContinuation = try ProviderContinuation(
      providerID: BuiltInProviderID.openAI,
      accountID: ProviderAccountID("account-1"),
      value: "response-1"
    )
    let openAIRequest = try makeRequest(
      providerID: BuiltInProviderID.openAI,
      continuation: openAIContinuation,
      constraints: optInConstraints
    )
    let openAIBody = try await encodedBody(
      OpenAIResponsesAdapter(kind: .openAI),
      request: openAIRequest
    )
    #expect(openAIBody["store"]?.boolValue == true)
    #expect(openAIBody["previous_response_id"]?.stringValue == "response-1")

    let initialOpenAIRequest = try makeRequest(
      providerID: BuiltInProviderID.openAI,
      constraints: optInConstraints
    )
    let initialOpenAIBody = try await encodedBody(
      OpenAIResponsesAdapter(kind: .openAI),
      request: initialOpenAIRequest
    )
    #expect(initialOpenAIBody["store"]?.boolValue == true)

    let defaultOpenAIRequest = try makeRequest(providerID: BuiltInProviderID.openAI)
    let defaultDecoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
      for: defaultOpenAIRequest
    )
    let defaultCompletion = try defaultDecoder.consume(
      .init(
        event: "response.completed",
        data: #"{"type":"response.completed","response":{"id":"response-1","status":"completed"}}"#,
        id: nil,
        retryMilliseconds: nil
      )
    )
    #expect(completionContinuation(defaultCompletion) == nil)

    let optedInDecoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
      for: initialOpenAIRequest
    )
    let optedInCompletion = try optedInDecoder.consume(
      .init(
        event: "response.completed",
        data: #"{"type":"response.completed","response":{"id":"response-1","status":"completed"}}"#,
        id: nil,
        retryMilliseconds: nil
      )
    )
    #expect(completionContinuation(optedInCompletion)?.value == "response-1")

    let codexContinuation = try ProviderContinuation(
      providerID: BuiltInProviderID.codex,
      accountID: ProviderAccountID("account-1"),
      value: "response-1"
    )
    let codexRequest = try makeRequest(
      providerID: BuiltInProviderID.codex,
      continuation: codexContinuation,
      constraints: optInConstraints
    )
    let directoryName = "providerkit-codex-continuation-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = directory.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"token","account_id":"account"}}"#.utf8).write(to: auth)
    let codexLease = ProviderCredentialLease(
      record: ProviderCredentialRecord(
        reference: try ProviderCredentialReference("codex-ref"),
        accountID: codexRequest.selection.accountID,
        providerID: BuiltInProviderID.codex,
        label: "Codex",
        source: .externalAuthFileReference,
        state: .active,
        endpoint: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      ),
      material: try ProviderCredentialMaterial(externalAuthFilePath: auth.path)
    )
    let codexAdapter = OpenAIResponsesAdapter(kind: .codex)
    await expectCapabilityMismatch {
      _ = try await codexAdapter.makeExecutionRequest(codexRequest, credential: codexLease)
    }
    let codexOptedInRequest = try makeRequest(
      providerID: BuiltInProviderID.codex,
      constraints: optInConstraints
    )
    let codexWire = try await codexAdapter.makeExecutionRequest(
      codexOptedInRequest,
      credential: codexLease
    )
    let codexBody = try ProviderJSONValue.decode(from: try #require(codexWire.urlRequest.httpBody))
    #expect(codexBody["store"]?.boolValue == false)
    let codexDecoder = try codexAdapter.makeDecoder(for: codexOptedInRequest)
    let codexCompletion = try codexDecoder.consume(
      .init(
        event: "response.completed",
        data: #"{"type":"response.completed","response":{"id":"response-1","status":"completed"}}"#,
        id: nil,
        retryMilliseconds: nil
      )
    )
    #expect(completionContinuation(codexCompletion) == nil)
  }

  @Test("Runtime rejects Codex continuation before opening the provider transport")
  func codexContinuationFailsBeforeWire() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("providerkit-codex-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = directory.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"token","account_id":"account"}}"#.utf8).write(to: auth)

    let account = try ProviderAccountID("codex-account")
    let continuation = try ProviderContinuation(
      providerID: BuiltInProviderID.codex,
      accountID: account,
      value: "response-1"
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.codex,
      accountID: account,
      continuation: continuation
    )
    let lease = ProviderCredentialLease(
      record: ProviderCredentialRecord(
        reference: try ProviderCredentialReference("codex-runtime-ref"),
        accountID: account,
        providerID: BuiltInProviderID.codex,
        label: "Codex",
        source: .externalAuthFileReference,
        state: .active,
        endpoint: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      ),
      material: try ProviderCredentialMaterial(externalAuthFilePath: auth.path)
    )
    let store = try TestCredentialStore(active: [lease])
    let transport = ScriptedTransport(scripts: [.json(status: 200, body: #"{}"#)])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )

    var terminals: [ProviderTerminal] = []
    for await event in await runtime.execute(request) {
      if case .terminal(let terminal) = event { terminals.append(terminal) }
    }
    await runtime.shutdown()
    guard terminals.count == 1, case .failed(let failure) = terminals[0] else {
      Issue.record("Codex continuation did not produce one terminal failure")
      return
    }
    #expect(failure.code == .capabilityMismatch)
    #expect(await transport.requestCount() == 0)
  }

  @Test("Provider decoders normalize native text, tools, usage, and completion")
  func decoders() throws {
    try verifyOpenAIResponsesDecoder()
    try verifyOpenAIChatDecoder()
    try verifyAnthropicDecoder()
    try verifyGeminiDecoder()
  }

  @Test("OpenRouter OAuth validates callback state, exchanges PKCE code, and registers once")
  func openRouterOAuth() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"key":"oauth-key"}"#),
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let pkce = try ProviderPKCE(
      codeVerifier: SensitiveValue(String(repeating: "v", count: 43)),
      codeChallenge: String(repeating: "c", count: 43),
      state: String(repeating: "s", count: 32)
    )
    let oauth = try OpenRouterOAuthRegistrationRequest(
      accountID: ProviderAccountID("oauth-account"),
      label: "OpenRouter OAuth",
      callbackURL: try #require(URL(string: "http://127.0.0.1:54321/oauth/openrouter")),
      pkce: pkce
    )
    let authorization = EchoAuthorizationSession(code: "authorization-code")
    let stream = try await runtime.registerOpenRouterOAuth(oauth, using: authorization)
    var events: [ProviderAccountPublicEvent] = []
    for await event in stream { events.append(event) }
    guard case .ready(let account) = events.last else {
      Issue.record("OAuth registration did not become ready")
      return
    }
    #expect(account.credentialSource == .oauthDerivedKey)
    let lease = try await store.lease(accountID: oauth.accountID)
    guard case .oauthDerivedKey(let key) = lease.material else {
      Issue.record("OAuth key did not retain its credential source")
      return
    }
    #expect(key.revealed == "oauth-key")

    let requests = await transport.requestsSnapshot()
    #expect(requests.count == 2)
    #expect(requests[0].url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
    let exchange = try ProviderJSONValue.decode(from: try #require(requests[0].httpBody))
    #expect(exchange["code"]?.stringValue == "authorization-code")
    #expect(exchange["code_verifier"]?.stringValue == String(repeating: "v", count: 43))
    let authRequest = try #require(await authorization.lastRequest())
    let authComponents = try #require(
      URLComponents(
        url: authRequest.authorizationURL,
        resolvingAgainstBaseURL: false
      ))
    #expect(
      authComponents.queryItems?.first(where: { $0.name == "code_challenge" })?.value
        == pkce.codeChallenge)
    #expect(
      authComponents.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value
        == "S256")
    #expect(!((authComponents.queryItems ?? []).contains { $0.name == "state" }))
    let callbackURL = try #require(
      authComponents.queryItems?.first(where: { $0.name == "callback_url" })?.value
    )
    let callbackComponents = try #require(URLComponents(string: callbackURL))
    #expect(
      callbackComponents.queryItems?.filter({ $0.name == "state" }).map(\.value) == [pkce.state]
    )

    await expectThrownProviderFailure {
      _ = try await runtime.registerOpenRouterOAuth(oauth, using: authorization)
    }
    await runtime.shutdown()
  }

  @Test("OpenRouter OAuth rejects callback mismatch before key exchange")
  func openRouterOAuthCallbackMismatch() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport(scripts: [])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let pkce = try ProviderPKCE(
      codeVerifier: SensitiveValue(String(repeating: "v", count: 43)),
      codeChallenge: String(repeating: "c", count: 43),
      state: String(repeating: "s", count: 32)
    )
    let oauth = try OpenRouterOAuthRegistrationRequest(
      accountID: ProviderAccountID("oauth-mismatch"),
      label: "OpenRouter OAuth",
      callbackURL: try #require(URL(string: "http://127.0.0.1:54321/oauth/openrouter")),
      pkce: pkce
    )
    let authorization = FixedAuthorizationSession(
      callbackURL: try #require(
        URL(string: "http://127.0.0.1:54321/oauth/other?state=wrong&code=bad"))
    )
    await expectThrownProviderFailure {
      _ = try await runtime.registerOpenRouterOAuth(oauth, using: authorization)
    }
    #expect(await transport.requestCount() == 0)
    await runtime.shutdown()
  }

  @Test("OpenRouter OAuth callback accepts only the exact expected query multiset")
  func openRouterOAuthRejectsUnexpectedOrDuplicateQueryItems() async throws {
    let state = String(repeating: "s", count: 32)
    let pkce = try ProviderPKCE(
      codeVerifier: SensitiveValue(String(repeating: "v", count: 43)),
      codeChallenge: String(repeating: "c", count: 43),
      state: state
    )
    let request = try OpenRouterOAuthRegistrationRequest(
      accountID: ProviderAccountID("oauth-strict-query"),
      label: "OpenRouter OAuth",
      callbackURL: try #require(
        URL(string: "http://127.0.0.1:54321/oauth/openrouter?tenant=semi")
      ),
      pkce: pkce
    )
    let callbacks = [
      "http://127.0.0.1:54321/oauth/openrouter?tenant=semi&state=\(state)&code=ok&extra=1",
      "http://127.0.0.1:54321/oauth/openrouter?tenant=semi&state=\(state)&state=\(state)&code=ok",
      "http://127.0.0.1:54321/oauth/openrouter?tenant=semi&state=\(state)&code=one&code=two",
      "http://127.0.0.1:54321/oauth/openrouter?tenant=semi&state=\(state)&code=ok&error=denied",
    ]

    for callback in callbacks {
      let transport = ScriptedTransport(scripts: [])
      let broker = OpenRouterOAuthBroker(
        transport: transport, clock: FixedProviderClock(date: Date(timeIntervalSince1970: 1)))
      let authorization = FixedAuthorizationSession(
        callbackURL: try #require(URL(string: callback))
      )
      await expectThrownProviderFailure {
        _ = try await broker.authorize(request, using: authorization)
      }
      #expect(await transport.requestCount() == 0)
    }
  }

  @Test("Startup reconciliation removes only staged credentials and reports cleanup failures")
  func startupCredentialReconciliation() async throws {
    let activeAccount = try ProviderAccountID("active-account")
    let removedAccount = try ProviderAccountID("staged-remove")
    let failedAccount = try ProviderAccountID("staged-fail")
    let active = try activeLease(accountID: activeAccount, providerID: BuiltInProviderID.openRouter)
    let store = try TestCredentialStore(active: [active])
    let removedRequest = try ProviderAccountRegistrationRequest(
      accountID: removedAccount,
      providerID: BuiltInProviderID.openRouter,
      label: "Interrupted",
      credential: .apiKey(SensitiveValue("staged-secret"))
    )
    let failedRequest = try ProviderAccountRegistrationRequest(
      accountID: failedAccount,
      providerID: BuiltInProviderID.openRouter,
      label: "Needs recovery",
      credential: .apiKey(SensitiveValue("staged-secret-2"))
    )
    let removedRecord = try await store.stage(removedRequest, at: Date(timeIntervalSince1970: 2))
    let failedRecord = try await store.stage(failedRequest, at: Date(timeIntervalSince1970: 3))
    await store.failRemoval(of: failedRecord.reference)

    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: ScriptedTransport(scripts: []),
      clock: SystemProviderClock()
    )
    let report = try await runtime.reconcileCredentials()

    #expect(report.activeRecordCount == 1)
    #expect(report.removedStagedReferences == [removedRecord.reference])
    #expect(report.issues.count == 1)
    #expect(report.issues.first?.reference == failedRecord.reference)
    #expect(report.issues.first?.failure.code == .credentialRecoveryRequired)
    #expect(report.requiresRecovery)

    let records = try await store.records()
    #expect(records.contains(where: { $0.accountID == activeAccount && $0.state == .active }))
    #expect(!records.contains(where: { $0.accountID == removedAccount }))
    #expect(records.contains(where: { $0.accountID == failedAccount && $0.state == .staged }))
  }

  @Test("Account registration stages, verifies, activates, and exposes readiness")
  func accountRegistration() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()
    let stream = await runtime.register(request)
    var events: [ProviderAccountPublicEvent] = []
    for await event in stream { events.append(event) }
    #expect(events.count == 4)
    #expect(events[0] == .staging)
    #expect(events[1] == .verifying)
    #expect(events[2] == .activating)
    guard case .ready(let summary) = events[3] else {
      Issue.record("registration did not finish ready")
      return
    }
    #expect(summary.accountID == request.accountID)
    #expect((try await store.lease(accountID: request.accountID)).record.state == .active)
    #expect(try await runtime.accounts().first?.readiness == .ready)
    await runtime.shutdown()
  }

  @Test("Persisted active accounts require verification after runtime restart")
  func persistedAccountRequiresVerification() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )

    let before = try #require(try await runtime.accounts().first)
    #expect(before.readiness == .verificationRequired)
    #expect(before.lastInspectedAt == nil)

    let inspection = try await runtime.inspect(accountID: account)
    #expect(inspection.readiness == .ready)
    let after = try #require(try await runtime.accounts().first)
    #expect(after.readiness == .ready)
    #expect(after.lastInspectedAt == inspection.inspectedAt)
    await runtime.shutdown()
  }

  @Test("Cancelling account registration waits for compensation and transport cleanup")
  func cancelRegistrationJoinsCleanup() async throws {
    let store = TestCredentialStore()
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()
    let stream = await runtime.register(request)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .staging)
    #expect(await iterator.next() == .verifying)
    await transport.waitUntilOpened()

    await runtime.cancelRegistration(accountID: request.accountID)

    guard case .failed(let failure) = await iterator.next() else {
      Issue.record("cancelled registration did not publish a terminal failure")
      return
    }
    #expect(failure.code == .cancelled)
    #expect(await iterator.next() == nil)
    #expect(await transport.wasCancelled())
    #expect(try await store.records().isEmpty)
    await runtime.shutdown()
  }

  @Test("Immediate registration cancellation joins before returning")
  func immediateRegistrationCancellation() async throws {
    let store = TestCredentialStore()
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()
    let stream = await runtime.register(request)
    await runtime.cancelRegistration(accountID: request.accountID)

    var terminal: ProviderAccountPublicEvent?
    for await event in stream where event.isTerminal { terminal = event }
    guard case .failed(let failure) = terminal else {
      Issue.record("immediate registration cancellation had no terminal failure")
      return
    }
    #expect(failure.code == .cancelled)
    #expect(try await store.records().isEmpty)
    await runtime.shutdown()
  }

  @Test("Cancellation after a non-cooperative stage compensates the stored credential")
  func cancellationAfterNonCooperativeStage() async throws {
    let stageGate = AsyncGate()
    let cancellationObserved = AsyncGate()
    let store = TestCredentialStore(
      stageGate: stageGate,
      stageCancellationObserved: cancellationObserved
    )
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: ScriptedTransport(scripts: []),
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()
    let stream = await runtime.register(request)
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == .staging)
    await stageGate.waitUntilObserved()
    let cancellation = Task {
      await runtime.cancelRegistration(accountID: request.accountID)
    }
    await cancellationObserved.wait()
    await stageGate.release()
    await cancellation.value

    guard case .failed(let failure) = await iterator.next() else {
      Issue.record("cancelled staged registration did not fail")
      return
    }
    #expect(failure.code == .cancelled)
    #expect(await iterator.next() == nil)
    #expect(try await store.records().isEmpty)
    #expect(try await runtime.accounts().isEmpty)
    await runtime.shutdown()
  }

  @Test("Cancellation before activation commit compensates an already active credential")
  func cancellationBeforeActivationCommit() async throws {
    let activationGate = AsyncGate()
    let cancellationObserved = AsyncGate()
    let store = TestCredentialStore(
      activationGate: activationGate,
      activationCancellationObserved: cancellationObserved
    )
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()
    let stream = await runtime.register(request)
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == .staging)
    #expect(await iterator.next() == .verifying)
    #expect(await iterator.next() == .activating)
    await activationGate.waitUntilObserved()
    let cancellation = Task {
      await runtime.cancelRegistration(accountID: request.accountID)
    }
    await cancellationObserved.wait()
    await activationGate.release()
    await cancellation.value

    guard case .failed(let failure) = await iterator.next() else {
      Issue.record("cancelled activation did not fail")
      return
    }
    #expect(failure.code == .cancelled)
    #expect(await iterator.next() == nil)
    #expect(try await store.records().isEmpty)
    #expect(try await runtime.accounts().isEmpty)
    await runtime.shutdown()
  }

  @Test("Runtime performs direct streaming and publishes one terminal")
  func runtimeStreaming() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"resp-1","choices":[{"delta":{"content":"hel"},"finish_reason":null}]}"#
            + "\n\n",
          #"data: {"id":"resp-1","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      )
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )
    let stream = await runtime.execute(request)
    var events: [ProviderTurnEvent] = []
    for await event in stream { events.append(event) }

    #expect(events.first.map { if case .started = $0 { true } else { false } } == true)
    #expect(
      events.compactMap { event in
        guard case .textDelta(let value) = event else { return nil }
        return value
      }.joined() == "hello")
    #expect(events.filter { if case .terminal = $0 { true } else { false } }.count == 1)
    guard case .terminal(.completed(let completion)) = events.last else {
      Issue.record("runtime did not complete")
      return
    }
    #expect(completion.responseID == "resp-1")
    #expect(completion.usage?.totalTokens == 3)
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("Runtime streams displayable reasoning separately from answer text")
  func runtimeReasoningStreaming() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"resp-reasoning","choices":[{"delta":{"reasoning_content":"consider"},"finish_reason":null}]}"#
            + "\n\n",
          #"data: {"id":"resp-reasoning","choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      )
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )
    let stream = await runtime.execute(request)
    var events: [ProviderTurnEvent] = []
    for await event in stream { events.append(event) }

    #expect(
      events.compactMap { event in
        guard case .reasoningDelta(let value) = event else { return nil }
        return value
      } == ["consider"])
    #expect(
      events.compactMap { event in
        guard case .textDelta(let value) = event else { return nil }
        return value
      } == ["answer"])
    #expect(events.filter { if case .terminal = $0 { true } else { false } }.count == 1)
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("URLSession transport fails cleanly when cancellation wins before start")
  func urlSessionPreStartCancellation() async throws {
    let gate = AsyncGate()
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:1/cancelled")))
    request.timeoutInterval = 1
    let wire = ProviderHTTPRequest(urlRequest: request, maximumResponseBytes: 1_024)
    let transport = URLSessionProviderHTTPTransport()

    let task = Task {
      await gate.wait()
      return try await transport.open(wire)
    }
    await gate.waitUntilObserved()
    task.cancel()
    await gate.release()

    do {
      _ = try await task.value
      Issue.record("pre-start cancellation unexpectedly opened a response")
    } catch is CancellationError {
      // Expected: cancellation is an ordinary terminal result, never a precondition crash.
    } catch {
      Issue.record("pre-start cancellation returned the wrong error: \(error)")
    }
  }

  @Test("HTTP failures become typed terminal failures instead of thrown streams")
  func runtimeHTTPFailure() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .json(status: 401, body: #"{"error":{"message":"bad api_key=secret-value"}}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let stream = await runtime.execute(
      try makeRequest(providerID: BuiltInProviderID.openRouter, accountID: account)
    )
    var terminal: ProviderTerminal?
    for await event in stream {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("HTTP failure was not terminal")
      return
    }
    #expect(failure.code == .authenticationFailed)
    #expect(!failure.message.contains("secret-value"))
    await runtime.shutdown()
  }

  @Test("Cancellation aborts transport and emits exactly one cancelled terminal")
  func cancellation() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )
    let stream = await runtime.execute(request)
    var iterator = stream.makeAsyncIterator()
    guard case .started = await iterator.next() else {
      Issue.record("stream did not start")
      return
    }
    await runtime.cancel(request.id)
    var terminals: [ProviderTerminal] = []
    while let event = await iterator.next() {
      if case .terminal(let terminal) = event { terminals.append(terminal) }
    }
    #expect(terminals == [.cancelled])
    #expect(await transport.wasCancelled())
    await runtime.shutdown()
  }

  @Test("Cancellation immediately after admission cannot be lost before session start")
  func immediateCancellationAfterAdmission() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"must-not-complete","choices":[{"delta":{"content":"wrong"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      )
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )

    let stream = await runtime.execute(request)
    await runtime.cancel(request.id)

    var terminals: [ProviderTerminal] = []
    for await event in stream {
      if case .terminal(let terminal) = event { terminals.append(terminal) }
    }
    #expect(terminals == [.cancelled])
    #expect(await transport.requestCount() == 0)
    await runtime.shutdown()
  }

  @Test("Retry stays on the same route and occurs only before visible output")
  func retryBeforeVisibleOutput() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .init(
        status: 429,
        headers: ["content-type": "application/json", "retry-after": "0"],
        chunks: [Data(#"{"error":{"message":"busy"}}"#.utf8)]
      ),
      .sse(
        status: 200,
        events: [
          #"data: {"id":"retry-ok","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      ),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(maximumRetryAttempts: 2)
    )
    var text = ""
    var terminal: ProviderTerminal?
    for await event in await runtime.execute(request) {
      switch event {
      case .textDelta(let delta): text += delta
      case .reasoningDelta:
        break
      case .terminal(let value): terminal = value
      case .started, .toolCall: break
      }
    }
    #expect(text == "ok")
    guard case .completed = terminal else {
      Issue.record("retryable pre-output failure did not recover")
      return
    }
    #expect(await transport.requestCount() == 2)
    await runtime.shutdown()
  }

  @Test("A successful HTTP response that fails before output retries without duplicate start")
  func retryAfterOpenedTransportFailsBeforeOutput() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .init(
        status: 200,
        headers: ["content-type": "text/event-stream"],
        chunks: [],
        completionError: .transport("connection reset before output")
      ),
      .sse(
        status: 200,
        events: [
          #"data: {"id":"retry-ok","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      ),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(maximumRetryAttempts: 2)
    )

    var events: [ProviderTurnEvent] = []
    for await event in await runtime.execute(request) { events.append(event) }

    #expect(events.filter { if case .started = $0 { true } else { false } }.count == 1)
    #expect(
      events.compactMap { event in
        guard case .textDelta(let value) = event else { return nil }
        return value
      }.joined() == "ok")
    guard case .terminal(.completed) = events.last else {
      Issue.record("opened transport failure did not recover")
      return
    }
    #expect(await transport.requestCount() == 2)
    await runtime.shutdown()
  }

  @Test("Malformed provider JSON remains a malformedResponse failure")
  func malformedProviderJSONClassification() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(status: 200, events: ["data: {not-json}\n\n"])
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )

    var terminal: ProviderTerminal?
    for await event in await runtime.execute(
      try makeRequest(providerID: BuiltInProviderID.openRouter, accountID: account)
    ) {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("malformed JSON did not fail")
      return
    }
    #expect(failure.code == .malformedResponse)
    await runtime.shutdown()
  }

  @Test("Runtime mailbox overflow becomes an explicit terminal failure")
  func runtimeMailboxOverflow() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let toolCalls: [ProviderJSONValue] = (0..<70).map { index in
      [
        "index": .number(Double(index)),
        "id": .string("call-\(index)"),
        "function": [
          "name": "lookup",
          "arguments": "{}",
        ],
      ]
    }
    let chunk: ProviderJSONValue = [
      "id": "overflow",
      "choices": [
        [
          "index": 0,
          "delta": ["tool_calls": .array(toolCalls)],
          "finish_reason": "tool_calls",
        ]
      ],
    ]
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          "data: \(String(decoding: try chunk.encodedData(), as: UTF8.self))\n\n",
          "data: [DONE]\n\n",
        ]
      )
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let tool = try ProviderToolDefinition(
      name: "lookup",
      description: "looks a value up",
      inputSchema: ["type": "object"]
    )
    let stream = await runtime.execute(
      try makeRequest(
        providerID: BuiltInProviderID.openRouter,
        accountID: account,
        tools: [tool]
      )
    )
    try await Task.sleep(for: .milliseconds(50))

    var terminal: ProviderTerminal?
    for await event in stream {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("runtime mailbox overflow did not fail")
      return
    }
    #expect(failure.code == .consumerBackpressureExceeded)
    await runtime.shutdown()
  }

  @Test("Transport backpressure is a terminal failure and is never retried")
  func transportBackpressureIsTerminal() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    // The bounded body stream drops chunks the execution cannot keep up with.
    // That is an upstream overrun, not a provider fault, so it must not retry.
    let transport = ScriptedTransport(scripts: [
      .init(
        status: 200,
        headers: ["content-type": "text/event-stream"],
        chunks: [],
        completionError: .consumerBackpressureExceeded
      ),
      .sse(status: 200, events: ["data: [DONE]\n\n"]),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(maximumRetryAttempts: 3)
    )
    var terminals: [ProviderTerminal] = []
    for await event in await runtime.execute(request) {
      if case .terminal(let value) = event { terminals.append(value) }
    }
    guard terminals.count == 1, case .failed(let failure) = terminals[0] else {
      Issue.record("transport backpressure did not produce exactly one terminal failure")
      return
    }
    #expect(failure.code == .consumerBackpressureExceeded)
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("Execute and shutdown interleave without losing or duplicating a terminal")
  func executeShutdownInterleaving() async throws {
    // A session releases its request ID for reuse before it publishes terminal,
    // but stays registered until `run()` returns. Race admission against
    // shutdown repeatedly so any regression in that split shows up here.
    for iteration in 0..<200 {
      let account = try ProviderAccountID("account-1")
      let store = try TestCredentialStore(active: [
        activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
      ])
      let transport = ScriptedTransport(scripts: [
        .sse(
          status: 200,
          events: [
            #"data: {"id":"resp","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
              + "\n\n",
            "data: [DONE]\n\n",
          ]
        )
      ])
      let runtime = ProviderRuntime(
        credentialStore: store,
        transport: transport,
        clock: SystemProviderClock()
      )
      let stream = await runtime.execute(
        try makeRequest(
          providerID: BuiltInProviderID.openRouter,
          accountID: account,
          requestID: "request-\(iteration)"
        )
      )
      async let shutdown: Void = runtime.shutdown()
      var terminals: [ProviderTerminal] = []
      for await event in stream {
        if case .terminal(let value) = event { terminals.append(value) }
      }
      await shutdown
      #expect(terminals.count == 1)
    }
  }

  @Test("Runtime never retries after a text delta is visible")
  func noRetryAfterVisibleOutput() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"partial","choices":[{"delta":{"content":"visible"},"finish_reason":null}]}"#
            + "\n\n"
        ]
      ),
      .sse(
        status: 200,
        events: [
          #"data: {"id":"must-not-run","choices":[{"delta":{"content":"wrong"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      ),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(maximumRetryAttempts: 2)
    )
    var text = ""
    var terminal: ProviderTerminal?
    for await event in await runtime.execute(request) {
      switch event {
      case .textDelta(let delta): text += delta
      case .reasoningDelta:
        break
      case .terminal(let value): terminal = value
      case .started, .toolCall: break
      }
    }
    #expect(text == "visible")
    guard case .failed(let failure) = terminal else {
      Issue.record("incomplete visible stream did not fail")
      return
    }
    #expect(failure.code == .malformedResponse)
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("Authentication failures are never retried")
  func noRetryForAuthenticationFailure() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = ScriptedTransport(scripts: [
      .json(status: 401, body: #"{"error":{"message":"bad key"}}"#),
      .json(status: 200, body: #"{"unexpected":true}"#),
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(maximumRetryAttempts: 3)
    )
    var terminal: ProviderTerminal?
    for await event in await runtime.execute(request) {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("authentication failure did not terminate")
      return
    }
    #expect(failure.code == .authenticationFailed)
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("Completed request IDs are reusable as soon as terminal is observable")
  func requestSessionReleaseOrdering() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let completed: [ScriptedTransport.Script] = [
      .sse(
        status: 200,
        events: [
          #"data: {"id":"first","choices":[{"delta":{"content":"one"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      ),
      .sse(
        status: 200,
        events: [
          #"data: {"id":"second","choices":[{"delta":{"content":"two"},"finish_reason":"stop"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ]
      ),
    ]
    let transport = ScriptedTransport(scripts: completed)
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )

    for expected in ["one", "two"] {
      let stream = await runtime.execute(request)
      var text = ""
      var terminal: ProviderTerminal?
      for await event in stream {
        switch event {
        case .textDelta(let delta): text += delta
        case .reasoningDelta:
          break
        case .terminal(let value): terminal = value
        case .started, .toolCall: break
        }
      }
      #expect(text == expected)
      guard case .completed = terminal else {
        Issue.record("request ID remained reserved after terminal")
        return
      }
    }
    #expect(await transport.requestCount() == 2)
    await runtime.shutdown()
  }

  @Test("Completed account registration is released before its terminal event")
  func registrationSessionReleaseOrdering() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try registrationRequest()

    for await _ in await runtime.register(request) {}

    let repeated = await runtime.register(request)
    var terminal: ProviderAccountPublicEvent?
    for await event in repeated { terminal = event }
    guard case .failed(let failure) = terminal else {
      Issue.record("repeated account registration did not fail")
      return
    }
    #expect(failure.message == "account already exists")
    #expect(await transport.requestCount() == 1)
    await runtime.shutdown()
  }

  @Test("Account revoke blocks new work, cancels active work, and removes credential")
  func revokeAccount() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account
    )
    let stream = await runtime.execute(request)
    var iterator = stream.makeAsyncIterator()
    guard case .started = await iterator.next() else {
      Issue.record("stream did not start before revoke")
      return
    }

    try await runtime.revoke(accountID: account)

    var terminals: [ProviderTerminal] = []
    while let event = await iterator.next() {
      if case .terminal(let value) = event { terminals.append(value) }
    }
    #expect(terminals == [.cancelled])
    #expect(await transport.wasCancelled())
    #expect(try await store.records().isEmpty)

    let rejected = await runtime.execute(request)
    var rejection: ProviderTerminal?
    for await event in rejected {
      if case .terminal(let value) = event { rejection = value }
    }
    guard case .failed(let failure) = rejection else {
      Issue.record("revoked account admitted new work")
      return
    }
    #expect(failure.code == .accountUnavailable)
    await runtime.shutdown()
  }

  @Test("Account revoke cancels only executions selected by the account index")
  func revokeUsesAccountExecutionIndex() async throws {
    let openRouterAccount = try ProviderAccountID("openrouter-account")
    let openAIAccount = try ProviderAccountID("openai-account")
    let store = try TestCredentialStore(active: [
      activeLease(
        accountID: openRouterAccount,
        providerID: BuiltInProviderID.openRouter
      ),
      activeLease(
        accountID: openAIAccount,
        providerID: BuiltInProviderID.openAI
      ),
    ])
    let transport = AccountScopedHangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let openRouterRequest = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: openRouterAccount,
      requestID: "openrouter-request"
    )
    let openAIRequest = try makeRequest(
      providerID: BuiltInProviderID.openAI,
      accountID: openAIAccount,
      requestID: "openai-request"
    )

    var openRouter = await runtime.execute(openRouterRequest).makeAsyncIterator()
    var openAI = await runtime.execute(openAIRequest).makeAsyncIterator()
    guard case .started = await openRouter.next(),
      case .started = await openAI.next()
    else {
      Issue.record("both account executions must start")
      return
    }

    try await runtime.revoke(accountID: openRouterAccount)
    #expect(await transport.wasCancelled(host: "openrouter.ai"))
    #expect(!(await transport.wasCancelled(host: "api.openai.com")))
    #expect(try await store.record(accountID: openRouterAccount) == nil)
    #expect(try await store.record(accountID: openAIAccount) != nil)

    await runtime.cancel(openAIRequest.id)
    #expect(await transport.wasCancelled(host: "api.openai.com"))
    await runtime.shutdown()
  }

  @Test("Failed credential removal leaves the existing account usable")
  func revokeFailureRestoresAvailability() async throws {
    let account = try ProviderAccountID("account-1")
    let reference = try ProviderCredentialReference("ref-account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    await store.failRemoval(of: reference)
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )

    do {
      try await runtime.revoke(accountID: account)
      Issue.record("credential removal failure was hidden")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .transportFailed)
    }

    let inspection = try await runtime.inspect(accountID: account)
    #expect(inspection.readiness == .ready)
    #expect(try await store.records().count == 1)
    await runtime.shutdown()
  }

  @Test("Deadline expiry is a timedOut terminal, not a cancellation")
  func timeout() async throws {
    let account = try ProviderAccountID("account-1")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: FastDeadlineClock()
    )
    let request = try makeRequest(
      providerID: BuiltInProviderID.openRouter,
      accountID: account,
      constraints: ProviderRequestConstraints(timeoutMilliseconds: 1_000)
    )
    let stream = await runtime.execute(request)
    var terminal: ProviderTerminal?
    for await event in stream {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("timeout did not fail")
      return
    }
    #expect(failure.code == .timedOut)
    await runtime.shutdown()
  }

  @Test("Strict wire helpers reject malformed catalogs, token usage, and oversized tool arguments")
  func strictWireValidation() throws {
    let malformedCatalogs = [
      #"{}"#,
      #"{"data":["not-an-object"]}"#,
      #"{"data":[{"id":"model-a"},{"id":"model-a"}]}"#,
      #"{"data":[{"id":"model-a","context_length":"invalid"}]}"#,
    ]
    for payload in malformedCatalogs {
      #expect(throws: ProviderFailure.self) {
        _ = try ProviderWireValidation.parseModelCatalog(
          data: Data(payload.utf8),
          candidateArrays: [["data"]],
          idKeys: ["id"],
          capabilities: ProviderCapabilities(),
          refreshedAt: Date(timeIntervalSince1970: 1)
        )
      }
    }
    do {
      _ = try ProviderWireValidation.parseModelCatalog(
        data: Data(
          #"{"data":[{"id":"catalog-secret"},{"id":"catalog-secret"}]}"#.utf8
        ),
        candidateArrays: [["data"]],
        idKeys: ["id"],
        capabilities: ProviderCapabilities(),
        refreshedAt: Date(timeIntervalSince1970: 1)
      )
      Issue.record("duplicate model catalog was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "model catalog contains duplicate identifiers")
      #expect(!failure.message.contains("catalog-secret"))
    }
    let catalog = try ProviderWireValidation.parseModelCatalog(
      data: Data(
        #"{"data":[{"id":"model-a","context_length":131072,"top_provider":{"max_completion_tokens":32768}},{"id":"model-b","max_tokens":64000}]}"#
          .utf8
      ),
      candidateArrays: [["data"]],
      idKeys: ["id"],
      capabilities: ProviderCapabilities(),
      refreshedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(catalog.models[0].maximumOutputTokens == 32_768)
    #expect(catalog.models[1].maximumOutputTokens == 64_000)

    var arguments = ProviderToolArgumentAccumulator(maximumBytes: 7)
    try arguments.append("{\"a\"")
    try arguments.append(":1}")
    #expect(arguments.byteCount == 7)
    #expect(try arguments.decodeObject() == ["a": 1])

    var bounded = ProviderToolArgumentAccumulator(maximumBytes: 4)
    try bounded.append("éé")
    #expect(bounded.byteCount == 4)
    #expect(throws: ProviderFailure.self) { try bounded.append("x") }

    #expect(ProviderJSONValue.number(Double.greatestFiniteMagnitude).integerValue == nil)

    let request = try makeRequest(providerID: BuiltInProviderID.openRouter)
    let chat = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(for: request)
    #expect(throws: ProviderFailure.self) {
      _ = try chat.consume(
        .init(
          event: nil,
          data: #"{"usage":{"prompt_tokens":"invalid"},"choices":[]}"#,
          id: nil,
          retryMilliseconds: nil
        ))
    }
  }

  @Test("Gemini model catalog duplicate diagnostics are redacted")
  func geminiModelCatalogDuplicateRedaction() async throws {
    let request = try makeRequest(providerID: BuiltInProviderID.gemini)
    let transport = ScriptedTransport(scripts: [
      .json(
        status: 200,
        body:
          #"{"models":[{"name":"models/gemini-catalog-secret"},{"name":"models/gemini-catalog-secret"}]}"#
      )
    ])
    do {
      _ = try await GeminiInteractionsAdapter().models(
        credential: try lease(for: request),
        transport: transport,
        clock: SystemProviderClock()
      )
      Issue.record("Gemini duplicate model catalog was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "Gemini model catalog contains duplicate identifiers")
      #expect(!failure.message.contains("gemini-catalog-secret"))
    }
  }

  @Test("OpenAI-compatible chat rejects malformed optional wire fields instead of dropping them")
  func openAIChatRejectsMalformedWireShapes() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.openRouter)
    let payloads = [
      #"{}"#,
      #"{"choices":{}}"#,
      #"{"choices":[{"index":0,"delta":{"content":42},"finish_reason":"stop"}]}"#,
      #"{"choices":[{"index":0,"delta":{"tool_calls":{}},"finish_reason":"stop"}]}"#,
      #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":{}}}]},"finish_reason":"tool_calls"}]}"#,
    ]
    for payload in payloads {
      let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(for: request)
      #expect(throws: ProviderFailure.self) {
        _ = try decoder.consume(
          .init(
            event: nil,
            data: payload,
            id: nil,
            retryMilliseconds: nil
          ))
      }
    }
  }

  @Test("OpenAI-compatible chat accepts a bounded usage-only terminal chunk")
  func openAIChatUsageOnlyChunk() throws {
    let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.openRouter)
    )
    _ = try decoder.consume(
      .init(
        event: nil,
        data:
          #"{"id":"usage-only","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: nil,
          data:
            #"{"id":"usage-only","usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    let completed = try decoder.consume(
      .init(event: nil, data: "[DONE]", id: nil, retryMilliseconds: nil)
    )
    guard case .completed(let draft) = completed.last else {
      Issue.record("usage-only chunk did not preserve completion")
      return
    }
    #expect(draft.usage?.totalTokens == 5)
  }

  @Test("Unexpected errors are normalized without reflecting descriptions")
  func unexpectedErrorRedaction() {
    let error = NSError(
      domain: "api_key=must-not-escape",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: "Bearer must-not-escape"]
    )
    let failure = ProviderWireError.failure(error)
    #expect(failure.code == .transportFailed)
    #expect(failure.message == "provider operation failed unexpectedly")
    #expect(!failure.message.contains("must-not-escape"))

    let timeout = ProviderWireError.failure(URLError(.timedOut))
    #expect(timeout.code == .timedOut)
    #expect(timeout.message == "provider network request timed out")
  }

  @Test("Provider SSE failures never expose remote diagnostics")
  func providerStreamErrorRedaction() throws {
    let secret = "secret-provider-diagnostic"

    func assertFailure(
      _ decoder: any ProviderStreamDecoder,
      event: ServerSentEvent,
      code: ProviderFailureCode,
      message: String
    ) {
      do {
        _ = try decoder.consume(event)
        Issue.record("provider SSE failure was accepted")
      } catch let failure as ProviderFailure {
        #expect(failure.code == code)
        #expect(failure.message == message)
        #expect(!failure.message.contains(secret))
      } catch {
        Issue.record("unexpected provider SSE error: \(error)")
      }
    }

    assertFailure(
      try OpenAIChatAdapter(kind: .openRouter).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openRouter)
      ),
      event: .init(
        event: nil,
        data: #"{"error":{"message":"secret-provider-diagnostic"}}"#,
        id: nil,
        retryMilliseconds: nil
      ),
      code: .serverFailed,
      message: "provider stream failed"
    )
    assertFailure(
      try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openAI)
      ),
      event: .init(
        event: "response.failed",
        data:
          #"{"type":"response.failed","response":{"error":{"message":"secret-provider-diagnostic"}}}"#,
        id: nil,
        retryMilliseconds: nil
      ),
      code: .serverFailed,
      message: "provider stream failed"
    )
    assertFailure(
      try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.anthropic)
      ),
      event: .init(
        event: "error",
        data:
          #"{"type":"error","error":{"type":"overloaded_error","message":"secret-provider-diagnostic"}}"#,
        id: nil,
        retryMilliseconds: nil
      ),
      code: .serverFailed,
      message: "Messages stream failed"
    )
    assertFailure(
      try GeminiInteractionsAdapter().makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.gemini)
      ),
      event: .init(
        event: "error",
        data: #"{"event_type":"error","error":{"message":"secret-provider-diagnostic"}}"#,
        id: nil,
        retryMilliseconds: nil
      ),
      code: .serverFailed,
      message: "Gemini stream failed"
    )
  }

  @Test("Anthropic deltas are bound to the content block type that opened them")
  func anthropicContentBlockTypeIsEnforced() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.anthropic)

    let textDecoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(for: request)
    _ = try textDecoder.consume(
      .init(
        event: "message_start",
        data: #"{"type":"message_start","message":{"id":"m1"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try textDecoder.consume(
      .init(
        event: "content_block_start",
        data:
          #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(throws: ProviderFailure.self) {
      _ = try textDecoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
    }

    let toolDecoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(for: request)
    _ = try toolDecoder.consume(
      .init(
        event: "message_start",
        data: #"{"type":"message_start","message":{"id":"m2"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try toolDecoder.consume(
      .init(
        event: "content_block_start",
        data:
          #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call-1","name":"lookup","input":{}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(throws: ProviderFailure.self) {
      _ = try toolDecoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"wrong"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
    }

    let qualifiedThinkingRequest = try makeRequest(
      providerID: BuiltInProviderID.anthropic,
      reasoning: .effort(.high)
    )
    let thinkingDecoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(
      for: qualifiedThinkingRequest
    )
    _ = try thinkingDecoder.consume(
      .init(
        event: "message_start",
        data: #"{"type":"message_start","message":{"id":"m3"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try thinkingDecoder.consume(
      .init(
        event: "content_block_start",
        data:
          #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try thinkingDecoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"summary"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ) == [.reasoningDelta("summary")])
    #expect(
      try thinkingDecoder.consume(
        .init(
          event: "content_block_stop",
          data: #"{"type":"content_block_stop","index":0}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
  }

  @Test("Anthropic private thinking and signatures are ignored without explicit summaries")
  func anthropicPrivateThinkingIsNotPublished() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.anthropic)
    let decoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(for: request)
    _ = try decoder.consume(
      .init(
        event: "message_start",
        data: #"{"type":"message_start","message":{"id":"private"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "content_block_start",
        data:
          #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"private","signature":"sig"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    #expect(
      try decoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    #expect(
      try decoder.consume(
        .init(
          event: "content_block_stop",
          data: #"{"type":"content_block_stop","index":0}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
  }

  @Test("OpenAI chat pins the first reasoning alias across the stream")
  func openAIChatReasoningAliasIsPinned() throws {
    let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.openRouter)
    )
    #expect(
      try decoder.consume(
        .init(
          event: nil,
          data: #"{"choices":[{"index":0,"delta":{"reasoning_content":"first"}}]}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ) == [.reasoningDelta("first")])
    do {
      _ = try decoder.consume(
        .init(
          event: nil,
          data: #"{"choices":[{"index":0,"delta":{"reasoning":"switched"}}]}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("chat reasoning alias switched without a malformed failure")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "chat stream changed reasoning field mid-response")
    }
  }

  @Test("Retry-After dates use the injected time and token totals fail on overflow")
  func deterministicRetryAfterAndUsageOverflow() throws {
    let failure = ProviderWireError.httpFailure(
      statusCode: 429,
      headers: ["retry-after": "Thu, 01 Jan 1970 00:00:02 GMT"],
      body: Data(#"{"error":{"message":"secret-provider-diagnostic"}}"#.utf8),
      now: Date(timeIntervalSince1970: 1)
    )
    #expect(failure.retryAfterMilliseconds == 1_000)
    #expect(failure.message == "provider HTTP request failed with status 429")
    #expect(!failure.message.contains("secret-provider-diagnostic"))

    let decoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(
      for: makeRequest(providerID: BuiltInProviderID.anthropic)
    )
    _ = try decoder.consume(
      .init(
        event: "message_start",
        data:
          #"{"type":"message_start","message":{"id":"overflow","usage":{"input_tokens":4611686018427387904}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "message_delta",
        data:
          #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4611686018427387904}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(throws: ProviderFailure.self) {
      _ = try decoder.consume(
        .init(
          event: "message_stop",
          data: #"{"type":"message_stop"}"#,
          id: nil,
          retryMilliseconds: nil
        ))
    }
  }

  @Test("Gemini text steps preserve their explicit start-delta-stop lifecycle")
  func geminiTextStepLifecycle() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.gemini)
    let decoder = try GeminiInteractionsAdapter().makeDecoder(for: request)
    _ = try decoder.consume(
      .init(
        event: "interaction.created",
        data: #"{"event_type":"interaction.created","interaction":{"id":"i-text"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "step.start",
          data:
            #"{"event_type":"step.start","index":0,"step":{"type":"model_output","content":[{"type":"text","text":"Once"}]}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.textDelta("Once")])
    #expect(
      try decoder.consume(
        .init(
          event: "step.delta",
          data: #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"hello"}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.textDelta("hello")])
    #expect(
      try decoder.consume(
        .init(
          event: "step.stop",
          data: #"{"event_type":"step.stop","index":0}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    #expect(
      try decoder.consume(
        .init(
          event: "interaction.completed",
          data:
            #"{"event_type":"interaction.completed","interaction":{"id":"i-text","status":"completed"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).count == 1)
    _ = try decoder.consume(.init(event: "done", data: "[DONE]", id: nil, retryMilliseconds: nil))
    #expect(try decoder.finish().isEmpty)
  }

  @Test("Gemini exposes displayable thought summaries and preserves initial function arguments")
  func geminiThoughtAndInitialFunctionArguments() throws {
    let request = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      reasoning: .effort(.high)
    )
    let decoder = try GeminiInteractionsAdapter().makeDecoder(for: request)
    #expect(
      try decoder.consume(
        .init(
          event: "step.start",
          data: #"{"event_type":"step.start","index":0,"step":{"type":"thought"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    #expect(
      try decoder.consume(
        .init(
          event: "step.delta",
          data:
            #"{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"summary"}}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("summary")])
    #expect(
      try decoder.consume(
        .init(
          event: "step.delta",
          data:
            #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"private reasoning"}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    _ = try decoder.consume(
      .init(
        event: "step.stop",
        data: #"{"event_type":"step.stop","index":0}"#,
        id: nil,
        retryMilliseconds: nil
      ))

    _ = try decoder.consume(
      .init(
        event: "step.start",
        data:
          #"{"event_type":"step.start","index":1,"step":{"type":"function_call","id":"call-1","name":"lookup","arguments":{"city":"Seoul"}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "step.stop",
          data: #"{"event_type":"step.stop","index":1}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [
          .toolCall(
            try ProviderToolCall(
              id: "call-1",
              name: "lookup",
              arguments: ["city": "Seoul"]
            ))
        ])
  }

  @Test("Gemini automatic reasoning does not publish thought summaries")
  func geminiAutomaticThoughtSummaryIsIgnored() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.gemini)
    let decoder = try GeminiInteractionsAdapter().makeDecoder(for: request)
    _ = try decoder.consume(
      .init(
        event: "step.start",
        data: #"{"event_type":"step.start","index":0,"step":{"type":"thought"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "step.delta",
          data:
            #"{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"provider summary"}}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
  }

  @Test("Gemini rejects deltas and stops that do not belong to an active step")
  func geminiRejectsInvalidStepLifecycle() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.gemini)
    let missingStart = try GeminiInteractionsAdapter().makeDecoder(for: request)
    #expect(throws: ProviderFailure.self) {
      _ = try missingStart.consume(
        .init(
          event: "step.delta",
          data: #"{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"orphan"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
    }

    let duplicate = try GeminiInteractionsAdapter().makeDecoder(for: request)
    let start = ServerSentEvent(
      event: "step.start",
      data: #"{"event_type":"step.start","index":0,"step":{"type":"model_output"}}"#,
      id: nil,
      retryMilliseconds: nil
    )
    _ = try duplicate.consume(start)
    #expect(throws: ProviderFailure.self) {
      _ = try duplicate.consume(start)
    }
  }

  @Test("Provider decoders fail closed on semantically unsuccessful terminal states")
  func semanticProviderFailures() throws {
    do {
      let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openRouter)
      )
      _ = try decoder.consume(
        .init(
          event: nil,
          data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(.init(event: nil, data: "[DONE]", id: nil, retryMilliseconds: nil))
      Issue.record("chat truncation was accepted as completion")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .serverFailed)
    }

    do {
      let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openAI)
      )
      _ = try decoder.consume(
        .init(
          event: "response.failed",
          data: #"{"type":"response.failed","response":{"error":{"message":"failed"}}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Responses failure was accepted as completion")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .serverFailed)
    }

    do {
      let decoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.anthropic)
      )
      _ = try decoder.consume(
        .init(
          event: "message_start",
          data: #"{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":1}}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(
        .init(
          event: "message_delta",
          data:
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":1}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(
        .init(
          event: "message_stop",
          data: #"{"type":"message_stop"}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Messages truncation was accepted as completion")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .serverFailed)
    }

    do {
      let decoder = try GeminiInteractionsAdapter().makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.gemini)
      )
      _ = try decoder.consume(
        .init(
          event: "interaction.completed",
          data:
            #"{"event_type":"interaction.completed","interaction":{"id":"i1","status":"failed"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Gemini failure was accepted as completion")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .serverFailed)
      #expect(failure.message == "Gemini interaction ended unsuccessfully")
    }
  }

  @Test("Remote termination values never enter public failure messages")
  func providerTerminationValueRedaction() throws {
    let sentinel = "remote-termination-sentinel"

    do {
      let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openRouter)
      )
      _ = try decoder.consume(
        .init(
          event: nil,
          data:
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"remote-termination-sentinel"}]}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(.init(event: nil, data: "[DONE]", id: nil, retryMilliseconds: nil))
      Issue.record("chat unsupported finish reason was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "chat stream ended with an unsupported finish reason")
      #expect(!failure.message.contains(sentinel))
    }

    do {
      let decoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.anthropic)
      )
      _ = try decoder.consume(
        .init(
          event: "message_start",
          data: #"{"type":"message_start","message":{"id":"termination"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(
        .init(
          event: "message_delta",
          data:
            #"{"type":"message_delta","delta":{"stop_reason":"remote-termination-sentinel"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      _ = try decoder.consume(
        .init(
          event: "message_stop",
          data: #"{"type":"message_stop"}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Messages unsupported stop reason was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "Messages stream ended with an unsupported stop reason")
      #expect(!failure.message.contains(sentinel))
    }

    do {
      let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.openAI)
      )
      _ = try decoder.consume(
        .init(
          event: "response.completed",
          data:
            #"{"type":"response.completed","response":{"id":"termination","status":"remote-termination-sentinel"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Responses unsuccessful status was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "provider emitted response.completed with an unsuccessful status")
      #expect(!failure.message.contains(sentinel))
    }

    do {
      let decoder = try GeminiInteractionsAdapter().makeDecoder(
        for: makeRequest(providerID: BuiltInProviderID.gemini)
      )
      _ = try decoder.consume(
        .init(
          event: "interaction.completed",
          data:
            #"{"event_type":"interaction.completed","interaction":{"id":"termination","status":"remote-termination-sentinel"}}"#,
          id: nil,
          retryMilliseconds: nil
        ))
      Issue.record("Gemini unsupported status was accepted")
    } catch let failure as ProviderFailure {
      #expect(failure.code == .malformedResponse)
      #expect(failure.message == "Gemini interaction ended with an unsupported status")
      #expect(!failure.message.contains(sentinel))
    }
  }

  @Test("Execution publishes terminal only after transport termination and uses the injected clock")
  func terminalWaitsForTransportTermination() async throws {
    let account = try ProviderAccountID("cleanup-account")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let gate = AsyncGate()
    let transport = DeferredTerminationTransport(gate: gate)
    let finishedAt = Date(timeIntervalSince1970: 1234)
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: FixedProviderClock(date: finishedAt)
    )
    let stream = await runtime.execute(
      try makeRequest(providerID: BuiltInProviderID.openRouter, accountID: account)
    )
    let probe = TerminalProbe()
    let consumer = Task {
      for await event in stream {
        if case .terminal(let terminal) = event { await probe.record(terminal) }
      }
    }

    await gate.waitUntilObserved()
    #expect(await probe.value() == nil)
    await gate.release()
    await consumer.value

    guard case .completed(let completion) = await probe.value() else {
      Issue.record("execution did not complete after transport termination")
      await runtime.shutdown()
      return
    }
    #expect(completion.finishedAt == finishedAt)
    await runtime.shutdown()
  }

  @Test("Registration rejects a no-op activation and compensates the staged credential")
  func activationReadBackIsRequired() async throws {
    let store = TestCredentialStore(noOpActivation: true)
    let transport = ScriptedTransport(scripts: [
      .json(status: 200, body: #"{"data":[{"id":"vendor/model"}]}"#)
    ])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    var terminal: ProviderAccountPublicEvent?
    for await event in await runtime.register(try registrationRequest()) { terminal = event }
    guard case .failed(let failure) = terminal else {
      Issue.record("no-op activation became ready")
      await runtime.shutdown()
      return
    }
    #expect(failure.code == .credentialRecoveryRequired)
    #expect(try await store.records().isEmpty)
    await runtime.shutdown()
  }

  @Test("Runtime rejects a credential lease whose material source disagrees with its record")
  func credentialSourceMismatchFailsBeforeTransport() async throws {
    let account = try ProviderAccountID("source-mismatch")
    let record = ProviderCredentialRecord(
      reference: try ProviderCredentialReference("ref-source-mismatch"),
      accountID: account,
      providerID: BuiltInProviderID.openRouter,
      label: "OpenRouter",
      source: .apiKey,
      state: .active,
      endpoint: nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let lease = ProviderCredentialLease(
      record: record,
      material: .oauthDerivedKey(try SensitiveValue("oauth-material"))
    )
    let store = try TestCredentialStore(active: [lease])
    let transport = ScriptedTransport(scripts: [])
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    var terminal: ProviderTerminal?
    for await event in await runtime.execute(
      try makeRequest(providerID: BuiltInProviderID.openRouter, accountID: account)
    ) {
      if case .terminal(let value) = event { terminal = value }
    }
    guard case .failed(let failure) = terminal else {
      Issue.record("mismatched credential source was accepted")
      await runtime.shutdown()
      return
    }
    #expect(failure.code == .credentialRecoveryRequired)
    #expect(await transport.requestCount() == 0)
    await runtime.shutdown()
  }

  @Test("Concurrent shutdown callers join active work and post-shutdown admission fails closed")
  func shutdownIsAJoiningAdmissionFence() async throws {
    let account = try ProviderAccountID("shutdown-account")
    let store = try TestCredentialStore(active: [
      activeLease(accountID: account, providerID: BuiltInProviderID.openRouter)
    ])
    let transport = HangingTransport()
    let runtime = ProviderRuntime(
      credentialStore: store,
      transport: transport,
      clock: SystemProviderClock()
    )
    let request = try makeRequest(providerID: BuiltInProviderID.openRouter, accountID: account)
    let stream = await runtime.execute(request)
    await transport.waitUntilOpened()

    async let first: Void = runtime.shutdown()
    async let second: Void = runtime.shutdown()
    _ = await (first, second)

    var activeTerminal: ProviderTerminal?
    for await event in stream {
      if case .terminal(let value) = event { activeTerminal = value }
    }
    #expect(activeTerminal == .cancelled)
    #expect(await transport.wasCancelled())

    var rejectedExecution: ProviderTerminal?
    for await event in await runtime.execute(request) {
      if case .terminal(let value) = event { rejectedExecution = value }
    }
    guard case .failed(let executionFailure) = rejectedExecution else {
      Issue.record("post-shutdown execution was admitted")
      return
    }
    #expect(executionFailure.code == .cancelled)

    var rejectedRegistration: ProviderAccountPublicEvent?
    for await event in await runtime.register(try registrationRequest()) {
      rejectedRegistration = event
    }
    guard case .failed(let registrationFailure) = rejectedRegistration else {
      Issue.record("post-shutdown registration was admitted")
      return
    }
    #expect(registrationFailure.code == .cancelled)
  }

  private func verifyOpenAIResponsesDecoder() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.openAI)
    let decoder = try OpenAIResponsesAdapter(kind: .openAI).makeDecoder(for: request)
    #expect(
      try decoder.consume(
        .init(
          event: "response.output_text.delta",
          data: #"{"type":"response.output_text.delta","delta":"ok"}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.textDelta("ok")])
    #expect(
      try decoder.consume(
        .init(
          event: "response.reasoning_summary_text.delta",
          data: #"{"type":"response.reasoning_summary_text.delta","delta":"plan"}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("plan")])
    #expect(
      try decoder.consume(
        .init(
          event: "response.reasoning_text.delta",
          data: #"{"type":"response.reasoning_text.delta","delta":"private"}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).isEmpty)
    let done = try decoder.consume(
      .init(
        event: "response.completed",
        data:
          #"{"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(done.count == 1)
    #expect(try decoder.finish().isEmpty)
  }

  private func verifyOpenAIChatDecoder() throws {
    let request = try makeRequest(providerID: BuiltInProviderID.openRouter)
    let decoder = try OpenAIChatAdapter(kind: .openRouter).makeDecoder(for: request)
    #expect(
      try decoder.consume(
        .init(
          event: nil,
          data: #"{"id":"r2","choices":[{"delta":{"content":"chat"},"finish_reason":"stop"}]}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.textDelta("chat")])
    #expect(
      try decoder.consume(
        .init(
          event: nil,
          data: #"{"id":"r2","choices":[{"delta":{"reasoning_content":"consider"}}]}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("consider")])
    #expect(
      try decoder.consume(
        .init(
          event: nil,
          data:
            #"{"id":"r2","choices":[{"delta":{"reasoning_content":"first","reasoning":"duplicate"}}]}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("first")])
    #expect(
      try decoder.consume(.init(event: nil, data: "[DONE]", id: nil, retryMilliseconds: nil)).count
        == 1)
    #expect(try decoder.finish().isEmpty)
  }

  private func verifyAnthropicDecoder() throws {
    let request = try makeRequest(
      providerID: BuiltInProviderID.anthropic,
      reasoning: .effort(.high)
    )
    let decoder = try AnthropicMessagesAdapter(kind: .anthropic).makeDecoder(for: request)
    _ = try decoder.consume(
      .init(
        event: "message_start",
        data: #"{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":1}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "content_block_start",
        data: #"{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"reason"}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("reason")])
    _ = try decoder.consume(
      .init(
        event: "content_block_stop",
        data: #"{"type":"content_block_stop","index":1}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "content_block_start",
        data:
          #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "content_block_delta",
          data:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"claude"}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.textDelta("claude")])
    _ = try decoder.consume(
      .init(
        event: "content_block_stop",
        data: #"{"type":"content_block_stop","index":0}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "message_delta",
        data:
          #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "message_stop",
          data: #"{"type":"message_stop"}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).count == 1)
    #expect(try decoder.finish().isEmpty)
  }

  private func verifyGeminiDecoder() throws {
    let request = try makeRequest(
      providerID: BuiltInProviderID.gemini,
      reasoning: .effort(.high)
    )
    let decoder = try GeminiInteractionsAdapter().makeDecoder(for: request)
    _ = try decoder.consume(
      .init(
        event: "interaction.created",
        data: #"{"event_type":"interaction.created","interaction":{"id":"i1"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "step.start",
        data:
          #"{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"c1","name":"lookup","arguments":{}}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    _ = try decoder.consume(
      .init(
        event: "step.delta",
        data:
          #"{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"id\":\"1\"}"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "step.stop",
          data: #"{"event_type":"step.stop","index":0}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).count == 1)
    _ = try decoder.consume(
      .init(
        event: "step.start",
        data: #"{"event_type":"step.start","index":1,"step":{"type":"thought"}}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "step.delta",
          data:
            #"{"event_type":"step.delta","index":1,"delta":{"type":"thought_summary","content":{"type":"text","text":"consider"}}}"#,
          id: nil,
          retryMilliseconds: nil
        )) == [.reasoningDelta("consider")])
    _ = try decoder.consume(
      .init(
        event: "step.stop",
        data: #"{"event_type":"step.stop","index":1}"#,
        id: nil,
        retryMilliseconds: nil
      ))
    #expect(
      try decoder.consume(
        .init(
          event: "interaction.completed",
          data:
            #"{"event_type":"interaction.completed","interaction":{"id":"i1","status":"requires_action","usage":{"total_input_tokens":2,"total_output_tokens":1,"total_tokens":3}}}"#,
          id: nil,
          retryMilliseconds: nil
        )
      ).count == 1)
    _ = try decoder.consume(.init(event: "done", data: "[DONE]", id: nil, retryMilliseconds: nil))
    #expect(try decoder.finish().isEmpty)
  }

  private func makeRequest(
    providerID: ProviderID,
    accountID: ProviderAccountID = try! ProviderAccountID("account-1"),
    tools: [ProviderToolDefinition] = [],
    toolChoice: ProviderToolChoice = .automatic,
    output: ProviderOutputRequirement = .text,
    reasoning: ProviderReasoningPolicy = .automatic,
    continuation: ProviderContinuation? = nil,
    requestID: String = "request-1",
    constraints: ProviderRequestConstraints = try! ProviderRequestConstraints()
  ) throws -> ProviderTurnRequest {
    try ProviderTurnRequest(
      id: ProviderRequestID(requestID),
      selection: ProviderSelection(
        providerID: providerID,
        accountID: accountID,
        modelID: ProviderModelID("vendor/model")
      ),
      messages: [try ProviderMessage(role: .user, text: "hello")],
      tools: tools,
      toolChoice: toolChoice,
      output: output,
      reasoning: reasoning,
      continuation: continuation,
      constraints: constraints
    )
  }

  private func encodedBody(
    _ adapter: any ProviderAdapter,
    request: ProviderTurnRequest
  ) async throws -> ProviderJSONValue {
    let wire = try await adapter.makeExecutionRequest(request, credential: try lease(for: request))
    return try ProviderJSONValue.decode(from: try #require(wire.urlRequest.httpBody))
  }

  private func completionContinuation(
    _ events: [ProviderDecodedEvent]
  ) -> ProviderContinuation? {
    for event in events {
      if case .completed(let draft) = event { return draft.continuation }
    }
    return nil
  }

  private func expectThrownProviderFailure(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      Issue.record("expected a provider failure", sourceLocation: sourceLocation)
    } catch is ProviderFailure {
      // Expected.
    } catch {
      Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
  }

  private func expectCapabilityMismatch(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      Issue.record(
        "unqualified provider dialect accepted the request", sourceLocation: sourceLocation)
    } catch let failure as ProviderFailure {
      #expect(failure.code == .capabilityMismatch, sourceLocation: sourceLocation)
    } catch {
      Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
  }

  private func lease(
    for request: ProviderTurnRequest,
    endpoint: ProviderEndpointConfiguration? = nil
  ) throws -> ProviderCredentialLease {
    try activeLease(
      accountID: request.selection.accountID,
      providerID: request.selection.providerID,
      endpoint: endpoint
    )
  }

  private func registrationRequest() throws -> ProviderAccountRegistrationRequest {
    try ProviderAccountRegistrationRequest(
      accountID: ProviderAccountID("account-1"),
      providerID: BuiltInProviderID.openRouter,
      label: "OpenRouter",
      credential: .apiKey(SensitiveValue("secret-key"))
    )
  }

  private func activeLease(
    accountID: ProviderAccountID,
    providerID: ProviderID,
    endpoint: ProviderEndpointConfiguration? = nil
  ) throws -> ProviderCredentialLease {
    ProviderCredentialLease(
      record: ProviderCredentialRecord(
        reference: try ProviderCredentialReference("ref-\(accountID.rawValue)"),
        accountID: accountID,
        providerID: providerID,
        label: providerID.rawValue,
        source: .apiKey,
        state: .active,
        endpoint: endpoint,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      ),
      material: .apiKey(try SensitiveValue("secret-key"))
    )
  }
}

private actor TestCredentialStore: ProviderCredentialStore {
  private struct Stored: Sendable {
    var record: ProviderCredentialRecord
    let material: ProviderCredentialMaterial
  }

  private var byAccount: [ProviderAccountID: Stored] = [:]
  private var removalFailures: Set<ProviderCredentialReference> = []
  private let stageGate: AsyncGate?
  private let stageCancellationObserved: AsyncGate?
  private let activationGate: AsyncGate?
  private let activationCancellationObserved: AsyncGate?
  private var noOpActivation: Bool

  init(
    stageGate: AsyncGate? = nil,
    stageCancellationObserved: AsyncGate? = nil,
    activationGate: AsyncGate? = nil,
    activationCancellationObserved: AsyncGate? = nil,
    noOpActivation: Bool = false
  ) {
    self.stageGate = stageGate
    self.stageCancellationObserved = stageCancellationObserved
    self.activationGate = activationGate
    self.activationCancellationObserved = activationCancellationObserved
    self.noOpActivation = noOpActivation
  }

  init(noOpActivation: Bool) {
    self.stageGate = nil
    self.stageCancellationObserved = nil
    self.activationGate = nil
    self.activationCancellationObserved = nil
    self.noOpActivation = noOpActivation
  }

  init(active leases: [ProviderCredentialLease]) throws {
    self.stageGate = nil
    self.stageCancellationObserved = nil
    self.activationGate = nil
    self.activationCancellationObserved = nil
    self.noOpActivation = false
    for lease in leases {
      guard lease.record.state == .active else {
        throw ProviderCoreError(code: .invalidValue, message: "test lease is not active")
      }
      byAccount[lease.record.accountID] = Stored(record: lease.record, material: lease.material)
    }
  }

  func stage(
    _ request: ProviderAccountRegistrationRequest,
    at date: Date
  ) async throws -> ProviderCredentialRecord {
    guard byAccount[request.accountID] == nil else {
      throw ProviderFailure(code: .invalidRequest, message: "account already exists")
    }
    let record = ProviderCredentialRecord(
      reference: try ProviderCredentialReference("ref-\(request.accountID.rawValue)"),
      accountID: request.accountID,
      providerID: request.providerID,
      label: request.label,
      source: request.credential.source,
      state: .staged,
      endpoint: request.endpoint,
      createdAt: date,
      updatedAt: date
    )
    byAccount[request.accountID] = Stored(record: record, material: request.credential)
    if let stageGate {
      let cancellationObserved = stageCancellationObserved
      await withTaskCancellationHandler {
        await stageGate.wait()
      } onCancel: {
        guard let cancellationObserved else { return }
        Task { await cancellationObserved.release() }
      }
    }
    return record
  }

  func activate(_ stagedRecord: ProviderCredentialRecord, at date: Date) async throws {
    if noOpActivation { return }
    guard let stored = byAccount[stagedRecord.accountID],
      stored.record.reference == stagedRecord.reference
    else {
      throw ProviderFailure(code: .accountUnavailable, message: "credential not found")
    }
    let old = stored.record
    let record = ProviderCredentialRecord(
      reference: old.reference,
      accountID: old.accountID,
      providerID: old.providerID,
      label: old.label,
      source: old.source,
      state: .active,
      endpoint: old.endpoint,
      createdAt: old.createdAt,
      updatedAt: date
    )
    byAccount[stagedRecord.accountID] = Stored(record: record, material: stored.material)
    if let activationGate {
      let cancellationObserved = activationCancellationObserved
      await withTaskCancellationHandler {
        await activationGate.wait()
      } onCancel: {
        guard let cancellationObserved else { return }
        Task { await cancellationObserved.release() }
      }
    }
  }

  func remove(_ record: ProviderCredentialRecord) async throws {
    if removalFailures.contains(record.reference) {
      throw ProviderFailure(
        code: .transportFailed,
        message: "injected credential removal failure"
      )
    }
    guard let stored = byAccount[record.accountID] else { return }
    guard stored.record.reference == record.reference else {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential identity mismatch"
      )
    }
    byAccount.removeValue(forKey: record.accountID)
  }

  func failRemoval(of reference: ProviderCredentialReference) {
    removalFailures.insert(reference)
  }

  func lease(accountID: ProviderAccountID) async throws -> ProviderCredentialLease {
    guard let stored = byAccount[accountID], stored.record.state == .active else {
      throw ProviderFailure(code: .accountUnavailable, message: "account is unavailable")
    }
    return ProviderCredentialLease(record: stored.record, material: stored.material)
  }

  func record(accountID: ProviderAccountID) async throws -> ProviderCredentialRecord? {
    byAccount[accountID]?.record
  }

  func records() async throws -> [ProviderCredentialRecord] {
    byAccount.values.map(\.record)
  }
}

private actor ScriptedTransport: ProviderHTTPTransport {
  struct Script: Sendable {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    let completionError: ProviderTransportError?

    init(
      status: Int,
      headers: [String: String],
      chunks: [Data],
      completionError: ProviderTransportError? = nil
    ) {
      self.status = status
      self.headers = headers
      self.chunks = chunks
      self.completionError = completionError
    }

    static func json(status: Int, body: String) -> Script {
      .init(
        status: status,
        headers: ["content-type": "application/json"],
        chunks: [Data(body.utf8)],
        completionError: nil
      )
    }

    static func sse(status: Int, events: [String]) -> Script {
      .init(
        status: status, headers: ["content-type": "text/event-stream"],
        chunks: events.map { Data($0.utf8) },
        completionError: nil
      )
    }
  }

  private var scripts: [Script]
  private var requests: [URLRequest] = []

  init(scripts: [Script]) {
    self.scripts = scripts
  }

  func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
    guard !scripts.isEmpty else {
      throw ProviderTransportError.transport("no scripted response")
    }
    requests.append(request.urlRequest)
    let script = scripts.removeFirst()
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      for chunk in script.chunks { continuation.yield(chunk) }
      if let completionError = script.completionError {
        continuation.finish(throwing: completionError)
      } else {
        continuation.finish()
      }
    }
    return ProviderHTTPResponse(
      statusCode: script.status,
      headers: script.headers,
      body: ProviderHTTPBodyStream(stream: stream),
      cancel: {}
    )
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [URLRequest] { requests }
}

private actor EchoAuthorizationSession: ProviderAuthorizationSession {
  private let code: String
  private var request: ProviderAuthorizationRequest?

  init(code: String) {
    self.code = code
  }

  func authorize(
    _ request: ProviderAuthorizationRequest
  ) async throws -> ProviderAuthorizationResult {
    self.request = request
    let components = try #require(
      URLComponents(
        url: request.authorizationURL,
        resolvingAgainstBaseURL: false
      ))
    let encodedCallback = try #require(
      components.queryItems?.first(where: { $0.name == "callback_url" })?.value
    )
    var callback = try #require(URLComponents(string: encodedCallback))
    var query = callback.queryItems ?? []
    query.append(URLQueryItem(name: "code", value: code))
    callback.queryItems = query
    return ProviderAuthorizationResult(callbackURL: try #require(callback.url))
  }

  func cancel() async {}
  func lastRequest() -> ProviderAuthorizationRequest? { request }
}

private actor FixedAuthorizationSession: ProviderAuthorizationSession {
  private let callbackURL: URL

  init(callbackURL: URL) {
    self.callbackURL = callbackURL
  }

  func authorize(
    _ request: ProviderAuthorizationRequest
  ) async throws -> ProviderAuthorizationResult {
    ProviderAuthorizationResult(callbackURL: callbackURL)
  }

  func cancel() async {}
}

private final class HangingBody: @unchecked Sendable {
  let stream: ProviderHTTPBodyStream
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
  private(set) var cancelled = false

  init() {
    let pair = AsyncThrowingStream<Data, any Error>.makeStream()
    stream = ProviderHTTPBodyStream(stream: pair.stream)
    continuation = pair.continuation
  }

  func cancel() {
    let continuation = withLock { () -> AsyncThrowingStream<Data, any Error>.Continuation? in
      guard !cancelled else { return nil }
      cancelled = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.finish(throwing: CancellationError())
  }

  func isCancelled() -> Bool { withLock { cancelled } }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private actor HangingTransport: ProviderHTTPTransport {
  private let body = HangingBody()
  private var opened = false
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
    opened = true
    let waiters = openWaiters
    openWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
    return ProviderHTTPResponse(
      statusCode: 200,
      headers: ["content-type": "text/event-stream"],
      body: body.stream,
      cancel: { [body] in body.cancel() }
    )
  }

  func waitUntilOpened() async {
    if opened { return }
    await withCheckedContinuation { continuation in
      openWaiters.append(continuation)
    }
  }

  func wasCancelled() -> Bool { body.isCancelled() }
}

private actor AccountScopedHangingTransport: ProviderHTTPTransport {
  private var bodies: [String: HangingBody] = [:]

  func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
    guard let host = request.urlRequest.url?.host else {
      throw ProviderTransportError.invalidResponse
    }
    let body = HangingBody()
    bodies[host] = body
    return ProviderHTTPResponse(
      statusCode: 200,
      headers: ["content-type": "text/event-stream"],
      body: body.stream,
      cancel: { [body] in body.cancel() }
    )
  }

  func wasCancelled(host: String) -> Bool {
    bodies[host]?.isCancelled() ?? false
  }
}

private actor AsyncGate {
  private var released = false
  private var observed = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var observationWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if !observed {
      observed = true
      let pending = observationWaiters
      observationWaiters.removeAll(keepingCapacity: false)
      for waiter in pending { waiter.resume() }
    }
    if released { return }
    await withCheckedContinuation { continuation in
      if released {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func waitUntilObserved() async {
    if observed { return }
    await withCheckedContinuation { continuation in
      if observed {
        continuation.resume()
      } else {
        observationWaiters.append(continuation)
      }
    }
  }

  func release() {
    guard !released else { return }
    released = true
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for waiter in pending { waiter.resume() }
  }
}

private actor TerminalProbe {
  private var terminal: ProviderTerminal?

  func record(_ value: ProviderTerminal) { terminal = value }
  func value() -> ProviderTerminal? { terminal }
}

private actor DeferredTerminationTransport: ProviderHTTPTransport {
  private let gate: AsyncGate

  init(gate: AsyncGate) { self.gate = gate }

  func open(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      continuation.yield(
        Data(
          (#"data: {"id":"cleanup","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
            + "\n\n").utf8
        ))
      continuation.yield(Data("data: [DONE]\n\n".utf8))
      continuation.finish()
    }
    return ProviderHTTPResponse(
      statusCode: 200,
      headers: ["content-type": "text/event-stream"],
      body: ProviderHTTPBodyStream(stream: stream),
      cancel: {},
      waitForTermination: { [gate] in await gate.wait() }
    )
  }
}

private struct FixedProviderClock: ProviderClock {
  let date: Date

  func now() async -> Date { date }

  func sleep(milliseconds: UInt64) async throws {
    let (nanoseconds, overflowed) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
    guard !overflowed else {
      throw ProviderCoreError(code: .invalidValue, message: "sleep overflow")
    }
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

private struct FastDeadlineClock: ProviderClock {
  func now() async -> Date { Date(timeIntervalSince1970: 10) }

  func sleep(milliseconds: UInt64) async throws {
    try await Task.sleep(nanoseconds: 20_000_000)
  }
}
