import Foundation
import SEMIProviderCore

package struct OpenAIChatAdapter: ProviderAdapter {
  package enum Kind: Equatable, Sendable {
    case openAICompatible
    case openRouter
    case xAI
    case deepSeek
    case qwen
    case kimi
  }

  package let kind: Kind

  package var descriptor: ProviderDescriptor {
    switch kind {
    case .openAICompatible:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.openAICompatible,
        name: "OpenAI-compatible",
        family: .openAIChatCompletions,
        apiKey: true,
        explicitEndpoint: true
      )
    case .openRouter:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.openRouter,
        name: "OpenRouter",
        family: .openAIChatCompletions,
        apiKey: true,
        oauth: true
      )
    case .xAI:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.xAI,
        name: "xAI",
        family: .openAIChatCompletions,
        apiKey: true
      )
    case .deepSeek:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.deepSeek,
        name: "DeepSeek",
        family: .openAIChatCompletions,
        apiKey: true
      )
    case .qwen:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.qwen,
        name: "Qwen",
        family: .openAIChatCompletions,
        apiKey: true,
        explicitEndpoint: true
      )
    case .kimi:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.kimi,
        name: "Kimi",
        family: .openAIChatCompletions,
        apiKey: true
      )
    }
  }

  package func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest {
    let key = try ProviderWireValidation.requireAuthentication(credential).value
    let base = try baseURL(for: credential.record)
    let endpoint = try ProviderWireValidation.appendPath("/chat/completions", to: base)
    var headers = [
      "Authorization": "Bearer \(key)",
      "Accept": "text/event-stream",
    ]
    if kind == .openRouter { headers["X-Title"] = "SEMI" }
    if kind == .kimi {
      headers["User-Agent"] = "KimiCLI/1.0"
      headers["X-Msh-Platform"] = "kimi_cli"
    }
    return try ProviderWireValidation.makeJSONRequest(
      url: endpoint,
      headers: headers,
      body: try encodeRequest(request),
      constraints: request.constraints
    )
  }

  package func makeDecoder(for request: ProviderTurnRequest) throws -> any ProviderStreamDecoder {
    OpenAIChatStreamDecoder()
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
      capabilities: capabilities,
      inspectedAt: await clock.now()
    )
  }

  package func models(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderModelCatalogResult {
    let key = try ProviderWireValidation.requireAuthentication(credential).value
    let base = try baseURL(for: credential.record)
    let endpoint = try ProviderWireValidation.appendPath("/models", to: base)
    let constraints = try ProviderRequestConstraints(
      timeoutMilliseconds: 60_000,
      maximumResponseBytes: 16 * 1_024 * 1_024,
      maximumRetryAttempts: 1
    )
    let response = try await transport.send(
      ProviderWireValidation.makeJSONRequest(
        url: endpoint,
        method: "GET",
        headers: ["Authorization": "Bearer \(key)"],
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
      idKeys: ["id", "model", "name"],
      capabilities: capabilities,
      refreshedAt: await clock.now()
    )
  }

  private var capabilities: ProviderCapabilities {
    ProviderDescriptorFactory.capabilities(
      structured: .declared(.providerDocumentation),
      reasoning: kind == .openRouter || kind == .deepSeek || kind == .kimi
        ? .declared(.providerDocumentation) : .unknown
    )
  }

  private func baseURL(for record: ProviderCredentialRecord) throws -> URL {
    if let configured = record.endpoint?.baseURL { return configured }
    switch kind {
    case .openAICompatible:
      guard let endpoint = record.endpoint?.baseURL else {
        throw ProviderFailure(
          code: .invalidRequest,
          message: "OpenAI-compatible mode requires an explicit endpoint"
        )
      }
      return endpoint
    case .openRouter: return ProviderEndpointCatalog.openRouter
    case .xAI: return record.endpoint?.baseURL ?? ProviderEndpointCatalog.xAI
    case .deepSeek: return ProviderEndpointCatalog.deepSeek
    case .qwen:
      throw ProviderFailure(
        code: .invalidRequest,
        message: "Qwen requires an explicit regional compatible-mode endpoint"
      )
    case .kimi: return ProviderEndpointCatalog.kimi
    }
  }

  private func encodeRequest(_ request: ProviderTurnRequest) throws -> ProviderJSONValue {
    if request.continuation != nil {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "chat-completions providers do not accept a Responses continuation"
      )
    }
    if case .jsonSchema = request.output,
      kind != .openRouter,
      kind != .kimi
    {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "strict JSON schema output is not qualified for this provider dialect"
      )
    }
    switch request.reasoning {
    case .automatic:
      break
    case .disabled, .effort:
      break
    }

    var messages: [ProviderJSONValue] = []
    for message in request.messages {
      if message.role == .tool {
        for item in message.content {
          guard case .toolResult(let callID, _, let value, _) = item else { continue }
          messages.append([
            "role": "tool",
            "tool_call_id": .string(callID),
            "content": .string(String(decoding: try value.encodedData(), as: UTF8.self)),
          ])
        }
        continue
      }
      if message.role == .assistant {
        let text = message.content.compactMap { item -> String? in
          guard case .text(let value) = item else { return nil }
          return value
        }.joined(separator: "\n")
        let toolCalls = try message.content.compactMap { item -> ProviderJSONValue? in
          guard case .toolCall(let callID, let name, let arguments) = item else { return nil }
          return [
            "id": .string(callID),
            "type": "function",
            "function": [
              "name": .string(name),
              "arguments": .string(String(decoding: try arguments.encodedData(), as: UTF8.self)),
            ],
          ]
        }
        var assistant: [String: ProviderJSONValue] = ["role": "assistant"]
        assistant["content"] = text.isEmpty ? .null : .string(text)
        if !toolCalls.isEmpty { assistant["tool_calls"] = .array(toolCalls) }
        messages.append(.object(assistant))
        continue
      }
      let role = message.role == .developer ? "system" : message.role.rawValue
      let text = message.content.compactMap { item -> String? in
        guard case .text(let value) = item else { return nil }
        return value
      }.joined(separator: "\n")
      guard !text.isEmpty else { continue }
      messages.append(["role": .string(role), "content": .string(text)])
    }

    var body: [String: ProviderJSONValue] = [
      "model": .string(request.selection.modelID.rawValue),
      "messages": .array(messages),
      "stream": true,
    ]
    body["stream_options"] = ["include_usage": true]
    if let maximumOutputTokens = request.constraints.maximumOutputTokens {
      let key = kind == .deepSeek ? "max_tokens" : "max_completion_tokens"
      body[key] = .number(Double(maximumOutputTokens))
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          [
            "type": "function",
            "function": [
              "name": .string(tool.name),
              "description": .string(tool.description),
              "parameters": tool.inputSchema,
              "strict": .bool(tool.strict),
            ],
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
          "function": ["name": .string(name)],
        ]
      }
    }
    switch request.output {
    case .text:
      break
    case .applicationValidatedJSON(let name, let schema):
      switch kind {
      case .openRouter, .kimi:
        body["response_format"] = [
          "type": "json_schema",
          "json_schema": [
            "name": .string(name),
            "schema": schema,
            "strict": true,
          ],
        ]
      case .openAICompatible, .xAI:
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "\(descriptor.displayName) does not declare application-validated JSON support"
        )
      case .deepSeek, .qwen:
        body["response_format"] = ["type": "json_object"]
        messages.insert(
          [
            "role": "system",
            "content": .string(
              "Return exactly one valid JSON object matching this application schema and no other text: "
                + String(decoding: try schema.encodedData(), as: UTF8.self)
            ),
          ],
          at: 0
        )
        body["messages"] = .array(messages)
      }
    case .jsonSchema(let name, let schema, let strict):
      body["response_format"] = [
        "type": "json_schema",
        "json_schema": [
          "name": .string(name),
          "schema": schema,
          "strict": .bool(strict),
        ],
      ]
    }
    switch (kind, request.reasoning) {
    case (_, .automatic):
      break
    case (.openRouter, .disabled):
      body["reasoning"] = ["enabled": false]
    case (.openRouter, .effort(let effort)):
      body["reasoning"] = ["effort": .string(effort.rawValue)]
    case (.deepSeek, .disabled):
      body["thinking"] = ["type": "disabled"]
    case (.deepSeek, .effort):
      body["thinking"] = ["type": "enabled"]
      body["reasoning_effort"] = "high"
    case (.qwen, .disabled):
      body["enable_thinking"] = false
    case (.qwen, .effort):
      body["enable_thinking"] = true
    case (.kimi, .disabled):
      body["thinking"] = ["type": "disabled"]
    case (.kimi, .effort):
      let forced = request.toolChoice != .automatic && !request.tools.isEmpty
      body["thinking"] = ["type": forced ? "disabled" : "enabled"]
    case (.openAICompatible, .disabled), (.openAICompatible, .effort),
      (.xAI, .disabled), (.xAI, .effort):
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "\(descriptor.displayName) does not declare reasoning controls"
      )
    }
    if kind == .openRouter {
      body["provider"] = [
        "allow_fallbacks": .bool(request.constraints.allowsProviderEndpointFallbacks),
        "require_parameters": .bool(request.constraints.requiresParameterSupport),
        "data_collection": .string(request.constraints.dataCollection.rawValue),
        "zdr": .bool(request.constraints.requiresZeroDataRetention),
      ]
    }
    return .object(body)
  }
}

private final class OpenAIChatStreamDecoder: ProviderStreamDecoder {
  private struct ToolState {
    var id: String?
    var name: String?
    var arguments = ProviderToolArgumentAccumulator()
  }

  private var responseID: String?
  private var usage: ProviderUsage?
  private var finishReason: String?
  private var reasoningAlias: String?
  private var tools: [Int: ToolState] = [:]
  private var completed = false

  func consume(_ event: ServerSentEvent) throws -> [ProviderDecodedEvent] {
    if event.data == "[DONE]" { return try complete() }
    let root = try ProviderWireValidation.decodeJSON(
      Data(event.data.utf8),
      field: "OpenAI chat stream JSON"
    )
    if root["error"] != nil {
      throw ProviderFailure(
        code: .serverFailed,
        message: "provider stream failed"
      )
    }
    _ = try ProviderWireValidation.object(root, field: "chat stream event")
    if let value = root["id"] {
      responseID = try optionalString(value, field: "chat response id") ?? responseID
    }
    let hasUsage = root["usage"] != nil
    if let value = root["usage"] { usage = try parseUsage(value) }

    var output: [ProviderDecodedEvent] = []
    guard let rawChoices = root["choices"] else {
      if hasUsage { return output }
      throw ProviderFailure(
        code: .malformedResponse, message: "chat stream event is missing choices")
    }
    let choices = try ProviderWireValidation.array(rawChoices, field: "chat choices")
    for choice in choices {
      _ = try ProviderWireValidation.object(choice, field: "chat choice")
      let choiceIndex = try ProviderWireValidation.nonnegativeInteger(
        choice["index"],
        defaultValue: 0,
        field: "chat choice index"
      )
      guard choiceIndex == 0 else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "chat stream returned multiple choices for a single-output request"
        )
      }
      if let rawReason = choice["finish_reason"],
        let reason = try optionalString(rawReason, field: "chat finish reason")
      {
        try recordFinishReason(reason)
      }
      guard let delta = choice["delta"] else {
        guard choice["finish_reason"] != nil else {
          throw ProviderFailure(code: .malformedResponse, message: "chat choice is missing delta")
        }
        continue
      }
      _ = try ProviderWireValidation.object(delta, field: "chat choice delta")
      if let rawContent = delta["content"],
        let content = try optionalString(rawContent, field: "chat content"),
        !content.isEmpty
      {
        output.append(.textDelta(content))
      }
      for field in ["reasoning_content", "reasoning", "reasoning_text"] {
        guard delta[field] != nil else { continue }
        if let reasoningAlias, reasoningAlias != field {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "chat stream changed reasoning field mid-response"
          )
        }
        self.reasoningAlias = reasoningAlias ?? field
        guard let rawReasoning = delta[field] else { continue }
        if let reasoning = try optionalString(rawReasoning, field: "chat reasoning"),
          !reasoning.isEmpty
        {
          output.append(.reasoningDelta(reasoning))
        }
        // These names are compatibility aliases. Accept exactly one to avoid
        // duplicate public output if an upstream response includes aliases.
        break
      }
      let rawCalls: [ProviderJSONValue]
      if let value = delta["tool_calls"] {
        if case .null = value {
          rawCalls = []
        } else {
          rawCalls = try ProviderWireValidation.array(value, field: "chat tool calls")
        }
      } else {
        rawCalls = []
      }
      for rawCall in rawCalls {
        _ = try ProviderWireValidation.object(rawCall, field: "chat tool call")
        let index = try ProviderWireValidation.nonnegativeInteger(
          rawCall["index"],
          defaultValue: 0,
          field: "chat tool-call index"
        )
        guard tools[index] != nil || tools.count < ProviderTurnRequest.maximumTools else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "chat stream exceeded tool-call state limit"
          )
        }
        var state = tools[index] ?? ToolState()
        if let value = rawCall["id"] {
          state.id = try optionalString(value, field: "chat tool call id") ?? state.id
        }
        if let function = rawCall["function"] {
          let object = try ProviderWireValidation.object(function, field: "chat tool function")
          if let value = object["name"] {
            state.name = try optionalString(value, field: "chat tool name") ?? state.name
          }
          if let value = object["arguments"],
            let arguments = try optionalString(value, field: "chat tool arguments")
          {
            try state.arguments.append(arguments)
          }
        }
        tools[index] = state
      }
    }
    return output
  }

  func finish() throws -> [ProviderDecodedEvent] {
    try complete()
  }

  private func complete() throws -> [ProviderDecodedEvent] {
    guard !completed else { return [] }
    guard let finishReason else {
      throw ProviderFailure(
        code: .malformedResponse, message: "chat stream ended without a completion marker")
    }
    switch finishReason {
    case "stop":
      guard tools.isEmpty else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "chat stream completed with stop while tool calls were pending"
        )
      }
    case "tool_calls", "function_call":
      guard !tools.isEmpty else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "chat stream declared tool completion without a tool call"
        )
      }
    case "length":
      throw ProviderFailure(
        code: .serverFailed, message: "chat response was truncated by its token limit")
    case "content_filter":
      throw ProviderFailure(
        code: .permissionDenied, message: "chat response was blocked by content filtering")
    case "insufficient_system_resource":
      throw ProviderFailure(
        code: .serverFailed, message: "chat provider reported insufficient system resources")
    default:
      throw ProviderFailure(
        code: .malformedResponse,
        message: "chat stream ended with an unsupported finish reason"
      )
    }
    completed = true
    var output: [ProviderDecodedEvent] = []
    for index in tools.keys.sorted() {
      guard let state = tools[index], let id = state.id, let name = state.name else {
        throw ProviderFailure(code: .malformedResponse, message: "chat tool call is incomplete")
      }
      let arguments = try state.arguments.decodeObject()
      output.append(.toolCall(try ProviderToolCall(id: id, name: name, arguments: arguments)))
    }
    output.append(
      .completed(
        ProviderCompletionDraft(
          responseID: responseID,
          continuation: nil,
          usage: usage
        )
      )
    )
    return output
  }

  private func recordFinishReason(_ value: String) throws {
    if let finishReason, finishReason != value {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "chat stream emitted conflicting finish reasons"
      )
    }
    finishReason = value
  }

  private func parseUsage(_ value: ProviderJSONValue) throws -> ProviderUsage {
    let object = try ProviderWireValidation.object(value, field: "chat usage")
    let prompt = object["prompt_tokens"] ?? object["input_tokens"]
    let completion = object["completion_tokens"] ?? object["output_tokens"]
    let cached =
      object["prompt_tokens_details"]?.objectValue?["cached_tokens"]
      ?? object["cached_tokens"]
    return try ProviderUsage(
      inputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        prompt,
        field: "chat input token count"
      ),
      outputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        completion,
        field: "chat output token count"
      ),
      cachedInputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        cached,
        field: "chat cached token count"
      ),
      totalTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_tokens"],
        field: "chat total token count"
      )
    )
  }

  private func optionalString(
    _ value: ProviderJSONValue,
    field: String
  ) throws -> String? {
    if case .null = value { return nil }
    guard let string = value.stringValue else {
      throw ProviderFailure(code: .malformedResponse, message: "\(field) is not a string")
    }
    return string
  }
}
