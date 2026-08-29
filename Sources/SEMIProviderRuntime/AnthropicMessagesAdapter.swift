import Foundation
import SEMIProviderCore

package struct AnthropicMessagesAdapter: ProviderAdapter {
  package enum Kind: Equatable, Sendable {
    case anthropic
    case zai
    case miniMax
  }

  package let kind: Kind

  package var descriptor: ProviderDescriptor {
    switch kind {
    case .anthropic:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.anthropic,
        name: "Anthropic",
        family: .anthropicMessages,
        apiKey: true
      )
    case .miniMax:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.miniMax,
        name: "MiniMax",
        family: .anthropicMessages,
        apiKey: true
      )
    case .zai:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.zai,
        name: "Z.AI",
        family: .anthropicMessages,
        apiKey: true
      )
    }
  }

  package func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest {
    guard request.continuation == nil else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Anthropic Messages does not accept a Responses continuation"
      )
    }
    if kind != .anthropic, case .jsonSchema = request.output {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "native JSON Schema output is not qualified for this Messages provider"
      )
    }
    if case .effort = request.reasoning, kind != .anthropic {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "explicit reasoning effort is not qualified for this Messages provider"
      )
    }
    let authentication = try ProviderWireValidation.requireAuthentication(credential)
    let base =
      credential.record.endpoint?.baseURL
      ?? {
        switch kind {
        case .anthropic: ProviderEndpointCatalog.anthropic
        case .zai: ProviderEndpointCatalog.zaiAnthropic
        case .miniMax: ProviderEndpointCatalog.miniMax
        }
      }()
    let endpoint = try ProviderWireValidation.appendPath("/v1/messages", to: base)
    let headers: [String: String]
    switch kind {
    case .anthropic:
      switch authentication {
      case .apiKey(let key):
        headers = [
          "x-api-key": key,
          "anthropic-version": "2023-06-01",
          "Accept": "text/event-stream",
        ]
      case .bearerToken(let token):
        headers = [
          "Authorization": "Bearer \(token)",
          "anthropic-version": "2023-06-01",
          "Accept": "text/event-stream",
        ]
      }
    case .zai, .miniMax:
      headers = [
        "Authorization": "Bearer \(authentication.value)",
        "anthropic-version": "2023-06-01",
        "Accept": "text/event-stream",
      ]
    }
    return try ProviderWireValidation.makeJSONRequest(
      url: endpoint,
      headers: headers,
      body: try encodeRequest(request),
      constraints: request.constraints
    )
  }

  package func makeDecoder(for request: ProviderTurnRequest) throws -> any ProviderStreamDecoder {
    let allowsDisplayableReasoning: Bool
    if case .effort = request.reasoning {
      allowsDisplayableReasoning = kind == .anthropic
    } else {
      allowsDisplayableReasoning = false
    }
    return AnthropicMessagesStreamDecoder(
      allowsDisplayableReasoning: allowsDisplayableReasoning
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
      capabilities: capabilities,
      inspectedAt: await clock.now()
    )
  }

  package func models(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderModelCatalogResult {
    let authentication = try ProviderWireValidation.requireAuthentication(credential)
    let endpoint: URL
    let headers: [String: String]
    switch kind {
    case .anthropic:
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.anthropic
      endpoint = try ProviderWireValidation.appendPath("/v1/models", to: base)
      switch authentication {
      case .apiKey(let key):
        headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
      case .bearerToken(let token):
        headers = ["Authorization": "Bearer \(token)", "anthropic-version": "2023-06-01"]
      }
    case .miniMax:
      let base = credential.record.endpoint?.baseURL ?? URL(string: "https://api.minimax.io")!
      endpoint = try ProviderWireValidation.appendPath("/v1/models", to: base)
      headers = ["Authorization": "Bearer \(authentication.value)"]
    case .zai:
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.zaiModels
      endpoint = try ProviderWireValidation.appendPath("/v1/models", to: base)
      headers = [
        "Authorization": "Bearer \(authentication.value)",
        "anthropic-version": "2023-06-01",
      ]
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
      idKeys: ["id", "model", "name"],
      capabilities: capabilities,
      refreshedAt: await clock.now()
    )
  }

  private var capabilities: ProviderCapabilities {
    ProviderDescriptorFactory.capabilities(
      structured: kind == .anthropic ? .declared(.providerDocumentation) : .unknown,
      reasoning: kind == .anthropic ? .declared(.providerDocumentation) : .unknown
    )
  }

  private func encodeRequest(_ request: ProviderTurnRequest) throws -> ProviderJSONValue {
    var system: [String] = []
    var messages: [ProviderJSONValue] = []
    for message in request.messages {
      if message.role == .system || message.role == .developer {
        system.append(
          contentsOf: message.content.compactMap { item in
            guard case .text(let text) = item else { return nil }
            return text
          })
        continue
      }
      if message.role == .tool {
        let blocks: [ProviderJSONValue] = try message.content.compactMap { item in
          guard case .toolResult(let callID, _, let value, let isError) = item else { return nil }
          var block: [String: ProviderJSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(callID),
            "content": .string(String(decoding: try value.encodedData(), as: UTF8.self)),
          ]
          if kind == .anthropic, isError { block["is_error"] = .bool(true) }
          return .object(block)
        }
        if !blocks.isEmpty { messages.append(["role": "user", "content": .array(blocks)]) }
        continue
      }
      let role = message.role == .assistant ? "assistant" : "user"
      let blocks = message.content.compactMap { item -> ProviderJSONValue? in
        switch item {
        case .text(let text):
          return ["type": "text", "text": .string(text)]
        case .toolCall(let callID, let name, let arguments):
          return [
            "type": "tool_use",
            "id": .string(callID),
            "name": .string(name),
            "input": arguments,
          ]
        case .toolResult:
          return nil
        }
      }
      if !blocks.isEmpty { messages.append(["role": .string(role), "content": .array(blocks)]) }
    }
    var body: [String: ProviderJSONValue] = [
      "model": .string(request.selection.modelID.rawValue),
      "max_tokens": .number(Double(request.constraints.maximumOutputTokens ?? 16_384)),
      "messages": .array(messages),
      "stream": true,
    ]
    if !system.isEmpty { body["system"] = .string(system.joined(separator: "\n\n")) }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          var value: [String: ProviderJSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema,
          ]
          if kind == .anthropic { value["strict"] = .bool(tool.strict) }
          return .object(value)
        })
      switch request.toolChoice {
      case .automatic:
        body["tool_choice"] = ["type": "auto"]
      case .required:
        body["tool_choice"] = ["type": "any"]
      case .named(let name):
        body["tool_choice"] = [
          "type": "tool",
          "name": .string(name),
        ]
      }
    }

    var outputConfig: [String: ProviderJSONValue] = [:]
    switch request.output {
    case .text:
      break
    case .applicationValidatedJSON(_, let schema):
      // SEMI validates the final bounded JSON value against this exact schema.
      // Use a native wire constraint only where the provider contract is qualified.
      if kind == .anthropic {
        outputConfig["format"] = [
          "type": "json_schema",
          "schema": schema,
        ]
      }
    case .jsonSchema(_, let schema, let strict):
      guard kind == .anthropic, strict else {
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "Anthropic structured output requires a strict native schema"
        )
      }
      outputConfig["format"] = [
        "type": "json_schema",
        "schema": schema,
      ]
    }
    switch request.reasoning {
    case .automatic:
      // Omitting `thinking` selects the model's own default. Forcing a mode here
      // would reject every model that does not implement extended thinking.
      break
    case .disabled:
      guard kind == .anthropic else {
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "explicit reasoning control is not qualified for MiniMax Messages"
        )
      }
      body["thinking"] = ["type": "disabled"]
    case .effort(let effort):
      guard kind == .anthropic else {
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "explicit reasoning control is not qualified for MiniMax Messages"
        )
      }
      body["thinking"] = ["type": "adaptive", "display": "summarized"]
      outputConfig["effort"] = .string(effort.rawValue)
    }
    if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
    return .object(body)
  }
}

private final class AnthropicMessagesStreamDecoder: ProviderStreamDecoder {
  private enum BlockKind {
    case text
    case reasoning
    case tool
    case ignored
  }

  private struct ToolState {
    let id: String
    let name: String
    var arguments = ProviderToolArgumentAccumulator()
    var initialInput: ProviderJSONValue?
  }

  private var responseID: String?
  private let allowsDisplayableReasoning: Bool
  private var inputTokens: Int?
  private var outputTokens: Int?
  private var cachedTokens: Int?
  private var tools: [Int: ToolState] = [:]
  private var activeBlocks: [Int: BlockKind] = [:]
  private var emittedToolCount = 0
  private var messageStarted = false
  private var stopReason: String?
  private var stopped = false

  init(allowsDisplayableReasoning: Bool) {
    self.allowsDisplayableReasoning = allowsDisplayableReasoning
  }

  func consume(_ event: ServerSentEvent) throws -> [ProviderDecodedEvent] {
    let root = try ProviderWireValidation.decodeJSON(
      Data(event.data.utf8),
      field: "Anthropic stream JSON"
    )
    let type = root["type"]?.stringValue ?? event.event
    switch type {
    case "message_start":
      guard !messageStarted, !stopped else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream emitted duplicate message_start")
      }
      messageStarted = true
      responseID = root.value(at: "message", "id")?.stringValue
      if let usage = root.value(at: "message", "usage") {
        let object = try ProviderWireValidation.object(usage, field: "Messages usage")
        inputTokens = try ProviderWireValidation.optionalNonnegativeInteger(
          object["input_tokens"],
          field: "Messages input token count"
        )
        cachedTokens = try ProviderWireValidation.optionalNonnegativeInteger(
          object["cache_read_input_tokens"],
          field: "Messages cached token count"
        )
        outputTokens = try ProviderWireValidation.optionalNonnegativeInteger(
          object["output_tokens"],
          field: "Messages output token count"
        )
      }
      return []
    case "content_block_start":
      guard messageStarted, let index = root["index"]?.integerValue, index >= 0,
        activeBlocks[index] == nil
      else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream has an invalid content block start")
      }
      guard let blockType = root.value(at: "content_block", "type")?.stringValue else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages content block has no type")
      }
      switch blockType {
      case "text":
        activeBlocks[index] = .text
        return []
      case "thinking":
        activeBlocks[index] = allowsDisplayableReasoning ? .reasoning : .ignored
        return []
      case "redacted_thinking", "fallback":
        activeBlocks[index] = .ignored
        return []
      case "tool_use":
        guard let id = root.value(at: "content_block", "id")?.stringValue,
          let name = root.value(at: "content_block", "name")?.stringValue,
          tools[index] == nil,
          emittedToolCount + tools.count < ProviderTurnRequest.maximumTools
        else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages tool block is invalid or exceeds its limit"
          )
        }
        activeBlocks[index] = .tool
        tools[index] = ToolState(
          id: id,
          name: name,
          initialInput: root.value(at: "content_block", "input")
        )
        return []
      default:
        // Anthropic may add content block types under its versioning policy.
        // Preserve the stream lifecycle without projecting unsupported block
        // payloads into SEMI's text/tool contract.
        activeBlocks[index] = .ignored
        return []
      }
    case "content_block_delta":
      guard messageStarted, let index = root["index"]?.integerValue,
        let blockKind = activeBlocks[index]
      else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream delta has no active content block")
      }
      let deltaType = root.value(at: "delta", "type")?.stringValue
      switch (blockKind, deltaType) {
      case (.text, "text_delta"):
        guard let text = root.value(at: "delta", "text")?.stringValue else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages text delta has no text")
        }
        return text.isEmpty ? [] : [.textDelta(text)]
      case (.reasoning, "thinking_delta"):
        guard let thinking = root.value(at: "delta", "thinking")?.stringValue else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages thinking delta has no text")
        }
        return thinking.isEmpty ? [] : [.reasoningDelta(thinking)]
      case (.reasoning, "signature_delta"):
        // Signatures are provider-private integrity state, not displayable
        // reasoning. Accept them without publishing or validating their
        // contents so a qualified summary stream remains well-formed.
        return []
      case (.tool, "input_json_delta"):
        guard let partial = root.value(at: "delta", "partial_json")?.stringValue,
          var tool = tools[index]
        else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages tool delta has no active tool block")
        }
        try tool.arguments.append(partial)
        tools[index] = tool
        return []
      case (.ignored, _):
        return []
      default:
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Messages content delta does not match its active block type"
        )
      }
    case "content_block_stop":
      guard let index = root["index"]?.integerValue,
        let blockKind = activeBlocks.removeValue(forKey: index)
      else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream stopped an unknown content block")
      }
      guard blockKind == .tool else { return [] }
      guard let tool = tools.removeValue(forKey: index) else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages tool block lost its state")
      }
      let arguments: ProviderJSONValue
      if tool.arguments.byteCount > 0 {
        arguments = try tool.arguments.decodeObject()
      } else if let initialInput = tool.initialInput {
        guard initialInput.objectValue != nil else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages tool input is not a JSON object")
        }
        arguments = initialInput
      } else {
        arguments = .object([:])
      }
      emittedToolCount += 1
      return [.toolCall(try ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments))]
    case "message_delta":
      guard messageStarted, activeBlocks.isEmpty else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Messages stream ended before its content blocks stopped")
      }
      if let usage = root["usage"] {
        let object = try ProviderWireValidation.object(usage, field: "Messages usage")
        inputTokens =
          try ProviderWireValidation.optionalNonnegativeInteger(
            object["input_tokens"],
            field: "Messages input token count"
          ) ?? inputTokens
        outputTokens =
          try ProviderWireValidation.optionalNonnegativeInteger(
            object["output_tokens"],
            field: "Messages output token count"
          ) ?? outputTokens
        cachedTokens =
          try ProviderWireValidation.optionalNonnegativeInteger(
            object["cache_read_input_tokens"],
            field: "Messages cached token count"
          ) ?? cachedTokens
      }
      if let reason = root.value(at: "delta", "stop_reason")?.stringValue {
        if let stopReason, stopReason != reason {
          throw ProviderFailure(
            code: .malformedResponse, message: "Messages stream emitted conflicting stop reasons")
        }
        stopReason = reason
      }
      return []
    case "message_stop":
      guard !stopped else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream emitted duplicate message_stop")
      }
      guard messageStarted, activeBlocks.isEmpty, tools.isEmpty else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream ended with an incomplete tool call")
      }
      guard let stopReason else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Messages stream ended without a stop reason")
      }
      switch stopReason {
      case "end_turn", "stop_sequence":
        break
      case "tool_use":
        guard emittedToolCount > 0 else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "Messages stream declared tool use without a tool call")
        }
      case "max_tokens":
        throw ProviderFailure(
          code: .serverFailed, message: "Messages response was truncated by its token limit")
      case "refusal":
        throw ProviderFailure(
          code: .permissionDenied, message: "Messages provider refused the response")
      case "pause_turn":
        throw ProviderFailure(
          code: .capabilityMismatch, message: "Messages pause_turn continuation is not supported")
      case "model_context_window_exceeded":
        throw ProviderFailure(
          code: .invalidRequest, message: "Messages request exceeded the model context window")
      default:
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Messages stream ended with an unsupported stop reason"
        )
      }
      stopped = true
      return [
        .completed(
          ProviderCompletionDraft(
            responseID: responseID,
            continuation: nil,
            usage: try ProviderUsage(
              inputTokens: inputTokens,
              outputTokens: outputTokens,
              cachedInputTokens: cachedTokens,
              totalTokens: try sum(inputTokens, outputTokens)
            )
          )
        )
      ]
    case "error":
      throw ProviderFailure(
        code: root.value(at: "error", "type")?.stringValue == "overloaded_error"
          ? .serverFailed : .transportFailed,
        message: "Messages stream failed"
      )
    case "ping":
      return []
    case .none:
      throw ProviderFailure(code: .malformedResponse, message: "Messages SSE event has no type")
    default:
      return []
    }
  }

  func finish() throws -> [ProviderDecodedEvent] {
    guard stopped else {
      throw ProviderFailure(
        code: .malformedResponse, message: "Messages stream ended before message_stop")
    }
    return []
  }

  private func sum(_ left: Int?, _ right: Int?) throws -> Int? {
    guard let left, let right else { return nil }
    let (sum, overflowed) = left.addingReportingOverflow(right)
    guard !overflowed else {
      throw ProviderFailure(code: .malformedResponse, message: "Messages token usage overflowed")
    }
    return sum
  }
}
