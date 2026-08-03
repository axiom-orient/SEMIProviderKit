import Foundation
import SEMIProviderCore

package struct OpenAIResponsesAdapter: ProviderAdapter {
  package enum Kind: Equatable, Sendable {
    case codex
    case openAI
  }

  package let kind: Kind

  package var descriptor: ProviderDescriptor {
    switch kind {
    case .codex:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.codex,
        name: "Codex (ChatGPT subscription)",
        family: .codexResponses,
        apiKey: false
      )
    case .openAI:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.openAI,
        name: "OpenAI",
        family: .openAIResponses,
        apiKey: true
      )
    }
  }

  package func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest {
    guard kind != .codex || request.continuation == nil else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Codex Responses continuation is not qualified"
      )
    }
    guard kind != .codex || request.constraints.maximumOutputTokens == nil else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Codex Responses maximum output tokens are not qualified"
      )
    }
    let endpoint: URL
    let headers: [String: String]
    switch kind {
    case .codex:
      let auth = try await CodexCredentialResolver.resolve(credential.material)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.codex
      endpoint = try ProviderWireValidation.appendPath("/responses", to: base)
      headers = [
        "Authorization": "Bearer \(auth.accessToken)",
        "ChatGPT-Account-ID": auth.accountID,
        "originator": "codex_cli_rs",
        "version": auth.clientVersion,
        "User-Agent": "codex-cli/\(auth.clientVersion)",
        "Accept": "text/event-stream",
      ]
    case .openAI:
      let key = try ProviderWireValidation.requireAPIKey(credential)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.openAI
      endpoint = try ProviderWireValidation.appendPath(
        credential.record.endpoint == nil ? "/v1/responses" : "/responses",
        to: base
      )
      headers = [
        "Authorization": "Bearer \(key)",
        "Accept": "text/event-stream",
      ]
    }
    let body = try encodeRequest(request)
    return try ProviderWireValidation.makeJSONRequest(
      url: endpoint,
      headers: headers,
      body: body,
      constraints: request.constraints
    )
  }

  package func makeDecoder(for request: ProviderTurnRequest) throws -> any ProviderStreamDecoder {
    OpenAIResponsesStreamDecoder(
      selection: request.selection,
      exposesContinuation: supportsServerSideContinuation
        && ProviderWireValidation.storesServerSideResponse(request)
    )
  }

  package func inspect(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderAccountInspection {
    _ = try await models(credential: credential, transport: transport, clock: clock)
    return try ProviderAccountInspection(
      accountID: credential.record.accountID,
      providerID: descriptor.id,
      readiness: .ready,
      capabilities: ProviderDescriptorFactory.capabilities(
        structured: .declared(.providerDocumentation),
        reasoning: .declared(.providerDocumentation)
      ),
      inspectedAt: await clock.now()
    )
  }

  package func models(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderModelCatalogResult {
    let endpoint: URL
    let headers: [String: String]
    switch kind {
    case .codex:
      let auth = try await CodexCredentialResolver.resolve(credential.material)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.codex
      var components = URLComponents(
        url: try ProviderWireValidation.appendPath("/models", to: base),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [URLQueryItem(name: "client_version", value: auth.clientVersion)]
      guard let url = components?.url else {
        throw ProviderFailure(code: .invalidRequest, message: "Codex model URL is invalid")
      }
      endpoint = url
      headers = [
        "Authorization": "Bearer \(auth.accessToken)",
        "ChatGPT-Account-ID": auth.accountID,
        "originator": "codex_cli_rs",
        "version": auth.clientVersion,
        "User-Agent": "codex-cli/\(auth.clientVersion)",
      ]
    case .openAI:
      let key = try ProviderWireValidation.requireAPIKey(credential)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.openAI
      endpoint = try ProviderWireValidation.appendPath(
        credential.record.endpoint == nil ? "/v1/models" : "/models",
        to: base
      )
      headers = ["Authorization": "Bearer \(key)"]
    }
    let constraints = try ProviderRequestConstraints(
      timeoutMilliseconds: 60_000,
      maximumResponseBytes: 8 * 1_024 * 1_024,
      maximumRetryAttempts: 1
    )
    let response = try await transport.send(
      ProviderWireValidation.makeJSONRequest(
        url: endpoint,
        method: "GET",
        headers: headers,
        body: nil,
        constraints: constraints
      )
    )
    guard (200..<300).contains(response.statusCode) else {
      throw ProviderWireError.httpFailure(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
        now: await clock.now()
      )
    }
    return try ProviderWireValidation.parseModelCatalog(
      data: response.body,
      candidateArrays: [["data"], ["models"]],
      idKeys: ["id", "slug"],
      capabilities: ProviderDescriptorFactory.capabilities(
        structured: .declared(.providerDocumentation),
        reasoning: .declared(.providerDocumentation)
      ),
      refreshedAt: await clock.now()
    )
  }

  private func encodeRequest(_ request: ProviderTurnRequest) throws -> ProviderJSONValue {
    if supportsServerSideContinuation {
      try ProviderWireValidation.requireServerSideContinuationOptIn(request)
    }
    var input: [ProviderJSONValue] = []
    var instructions: [String] = []
    for message in request.messages {
      if kind == .codex, message.role == .system || message.role == .developer {
        instructions.append(contentsOf: message.content.compactMap(\.textValue))
        continue
      }
      if message.role == .tool {
        for content in message.content {
          guard case .toolResult(let callID, _, let value, _) = content else { continue }
          input.append([
            "type": "function_call_output",
            "call_id": .string(callID),
            "output": .string(String(decoding: try value.encodedData(), as: UTF8.self)),
          ])
        }
        continue
      }
      if message.role == .assistant {
        let items = message.content.compactMap { item -> ProviderJSONValue? in
          guard case .text(let text) = item else { return nil }
          return ["type": "output_text", "text": .string(text)]
        }
        if !items.isEmpty {
          input.append([
            "type": "message",
            "role": "assistant",
            "content": .array(items),
          ])
        }
        for content in message.content {
          guard case .toolCall(let callID, let name, let arguments) = content else { continue }
          input.append([
            "type": "function_call",
            "call_id": .string(callID),
            "name": .string(name),
            "arguments": .string(String(decoding: try arguments.encodedData(), as: UTF8.self)),
          ])
        }
        continue
      }
      let contentType = "input_text"
      let items = message.content.compactMap { item -> ProviderJSONValue? in
        guard case .text(let text) = item else { return nil }
        return ["type": .string(contentType), "text": .string(text)]
      }
      guard !items.isEmpty else { continue }
      input.append([
        "type": "message",
        "role": .string(message.role.rawValue),
        "content": .array(items),
      ])
    }

    var body: [String: ProviderJSONValue] = [
      "model": .string(request.selection.modelID.rawValue),
      "input": .array(input),
      "stream": true,
      "store": .bool(
        supportsServerSideContinuation
          && ProviderWireValidation.storesServerSideResponse(request)
      ),
    ]
    if let maximumOutputTokens = request.constraints.maximumOutputTokens {
      body["max_output_tokens"] = .number(Double(maximumOutputTokens))
    }
    if kind == .codex, !instructions.isEmpty {
      body["instructions"] = .string(instructions.joined(separator: "\n\n"))
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          [
            "type": "function",
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.inputSchema,
            "strict": .bool(tool.strict),
          ]
        })
      switch request.toolChoice {
      case .automatic:
        body["tool_choice"] = "auto"
      case .required:
        body["tool_choice"] = "required"
      case .named(let name):
        body["tool_choice"] = [
          "type": "function",
          "name": .string(name),
        ]
      }
      body["parallel_tool_calls"] = false
    }
    switch request.output {
    case .text:
      break
    case .applicationValidatedJSON(let name, let schema):
      body["text"] = [
        "format": [
          "type": "json_schema",
          "name": .string(name),
          "schema": schema,
          "strict": true,
        ]
      ]
    case .jsonSchema(let name, let schema, let strict):
      body["text"] = [
        "format": [
          "type": "json_schema",
          "name": .string(name),
          "schema": schema,
          "strict": .bool(strict),
        ]
      ]
    }
    switch request.reasoning {
    case .automatic:
      break
    case .disabled:
      // Responses expresses "no reasoning" as a model-specific effort level
      // ("none" or "minimal"), so no single wire value is qualified here.
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "disabling reasoning is not qualified for the Responses dialect"
      )
    case .effort(let effort):
      body["reasoning"] = ["effort": .string(effort.rawValue)]
    }
    if let continuation = request.continuation {
      body["previous_response_id"] = .string(continuation.value)
    }
    return .object(body)
  }

  private var supportsServerSideContinuation: Bool {
    kind == .openAI
  }
}

extension ProviderMessageContent {
  fileprivate var textValue: String? {
    guard case .text(let text) = self else { return nil }
    return text
  }
}

private final class OpenAIResponsesStreamDecoder: ProviderStreamDecoder {
  private struct ToolState {
    var callID: String?
    var name: String?
    var arguments = ProviderToolArgumentAccumulator()
    var emitted = false
  }

  private let selection: ProviderSelection
  private let exposesContinuation: Bool
  private var responseID: String?
  private var usage: ProviderUsage?
  private var tools: [String: ToolState] = [:]
  private var completed = false

  init(selection: ProviderSelection, exposesContinuation: Bool) {
    self.selection = selection
    self.exposesContinuation = exposesContinuation
  }

  func consume(_ event: ServerSentEvent) throws -> [ProviderDecodedEvent] {
    guard event.data != "[DONE]" else { return [] }
    let root = try ProviderWireValidation.decodeJSON(
      Data(event.data.utf8),
      field: "OpenAI Responses stream JSON"
    )
    let type = root["type"]?.stringValue ?? event.event
    switch type {
    case "response.created", "response.in_progress":
      responseID = root.value(at: "response", "id")?.stringValue ?? responseID
      return []
    case "response.output_text.delta":
      guard let delta = root["delta"]?.stringValue, !delta.isEmpty else { return [] }
      return [.textDelta(delta)]
    case "response.output_item.added":
      guard root.value(at: "item", "type")?.stringValue == "function_call" else { return [] }
      let key = try toolKey(root)
      var state = tools[key] ?? ToolState()
      state.callID = root.value(at: "item", "call_id")?.stringValue ?? state.callID
      state.name = root.value(at: "item", "name")?.stringValue ?? state.name
      if let arguments = root.value(at: "item", "arguments")?.stringValue, !arguments.isEmpty {
        try state.arguments.replace(with: arguments)
      }
      tools[key] = state
      return []
    case "response.function_call_arguments.delta":
      let key = try toolKey(root)
      var state = tools[key] ?? ToolState()
      if let delta = root["delta"]?.stringValue { try state.arguments.append(delta) }
      tools[key] = state
      return []
    case "response.function_call_arguments.done":
      let key = try toolKey(root)
      var state = tools[key] ?? ToolState()
      if let arguments = root["arguments"]?.stringValue {
        try state.arguments.replace(with: arguments)
      }
      tools[key] = state
      return try emitTool(key: key)
    case "response.output_item.done":
      guard root.value(at: "item", "type")?.stringValue == "function_call" else { return [] }
      let key = try toolKey(root)
      var state = tools[key] ?? ToolState()
      state.callID = root.value(at: "item", "call_id")?.stringValue ?? state.callID
      state.name = root.value(at: "item", "name")?.stringValue ?? state.name
      if let arguments = root.value(at: "item", "arguments")?.stringValue {
        try state.arguments.replace(with: arguments)
      }
      tools[key] = state
      return try emitTool(key: key)
    case "response.completed":
      guard !completed else {
        throw ProviderFailure(
          code: .malformedResponse, message: "provider emitted duplicate completion")
      }
      let response = root["response"] ?? root
      if let status = response["status"]?.stringValue, status != "completed" {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "provider emitted response.completed with status \(status)"
        )
      }
      guard tools.values.allSatisfy(\.emitted) else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "provider completed with an unfinished tool call"
        )
      }
      completed = true
      responseID = response["id"]?.stringValue ?? responseID
      usage = try parseUsage(response["usage"])
      let continuation: ProviderContinuation?
      if exposesContinuation, let responseID {
        continuation = try ProviderContinuation(
          providerID: selection.providerID,
          accountID: selection.accountID,
          value: responseID
        )
      } else {
        continuation = nil
      }
      return [
        .completed(
          ProviderCompletionDraft(
            responseID: responseID,
            continuation: continuation,
            usage: usage
          )
        )
      ]
    case "response.failed", "error":
      let message =
        root.value(at: "response", "error", "message")?.stringValue
        ?? root.value(at: "error", "message")?.stringValue
        ?? "provider stream failed"
      throw ProviderFailure(code: .serverFailed, message: message)
    case "response.incomplete":
      throw ProviderFailure(code: .serverFailed, message: "provider response was incomplete")
    case "response.refusal.delta", "response.refusal.done":
      throw ProviderFailure(code: .permissionDenied, message: "provider refused the response")
    case .none:
      throw ProviderFailure(code: .malformedResponse, message: "provider SSE event has no type")
    default:
      return []
    }
  }

  func finish() throws -> [ProviderDecodedEvent] {
    guard completed else {
      throw ProviderFailure(
        code: .malformedResponse, message: "provider stream ended before response.completed")
    }
    return []
  }

  private func toolKey(_ root: ProviderJSONValue) throws -> String {
    if let value = root.value(at: "item", "id")?.stringValue ?? root["item_id"]?.stringValue {
      return value
    }
    guard let rawIndex = root["output_index"] else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "Responses tool event is missing its item identity"
      )
    }
    let index = try ProviderWireValidation.nonnegativeInteger(
      rawIndex,
      defaultValue: 0,
      field: "Responses output index"
    )
    return "index:\(index)"
  }

  private func emitTool(key: String) throws -> [ProviderDecodedEvent] {
    guard var state = tools[key], !state.emitted else { return [] }
    guard let callID = state.callID ?? (key.hasPrefix("index:") ? nil : key),
      let name = state.name
    else {
      throw ProviderFailure(
        code: .malformedResponse, message: "provider tool call is missing its identity")
    }
    let arguments = try state.arguments.decodeObject()
    let call = try ProviderToolCall(id: callID, name: name, arguments: arguments)
    state.emitted = true
    tools[key] = state
    return [.toolCall(call)]
  }

  private func parseUsage(_ value: ProviderJSONValue?) throws -> ProviderUsage? {
    guard let value else { return nil }
    let object = try ProviderWireValidation.object(value, field: "Responses usage")
    let cached = object["input_tokens_details"]?.objectValue?["cached_tokens"]
    return try ProviderUsage(
      inputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["input_tokens"],
        field: "Responses input token count"
      ),
      outputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["output_tokens"],
        field: "Responses output token count"
      ),
      cachedInputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        cached,
        field: "Responses cached token count"
      ),
      totalTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_tokens"],
        field: "Responses total token count"
      )
    )
  }
}
