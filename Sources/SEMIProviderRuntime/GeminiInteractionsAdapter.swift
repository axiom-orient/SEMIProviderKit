import Foundation
import SEMIProviderCore

package struct GeminiInteractionsAdapter: ProviderAdapter {
  package init() {}

  package var descriptor: ProviderDescriptor {
    ProviderDescriptorFactory.make(
      id: BuiltInProviderID.gemini,
      name: "Google Gemini",
      family: .geminiInteractions,
      apiKey: true
    )
  }

  package func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest {
    let key = try ProviderWireValidation.requireAPIKey(credential)
    let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.gemini
    var components = URLComponents(
      url: try ProviderWireValidation.appendPath("/v1beta/interactions", to: base),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
    guard let endpoint = components?.url else {
      throw ProviderFailure(code: .invalidRequest, message: "Gemini interaction URL is invalid")
    }
    return try ProviderWireValidation.makeJSONRequest(
      url: endpoint,
      headers: [
        "x-goog-api-key": key,
        "Accept": "text/event-stream",
      ],
      body: try encodeRequest(request),
      constraints: request.constraints
    )
  }

  package func makeDecoder(for request: ProviderTurnRequest) throws -> any ProviderStreamDecoder {
    let allowsDisplayableReasoning: Bool
    if case .effort = request.reasoning {
      allowsDisplayableReasoning = true
    } else {
      allowsDisplayableReasoning = false
    }
    return GeminiInteractionsStreamDecoder(
      selection: request.selection,
      exposesContinuation: ProviderWireValidation.storesServerSideResponse(request),
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
    let key = try ProviderWireValidation.requireAPIKey(credential)
    let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.gemini
    let endpoint = try ProviderWireValidation.appendPath("/v1beta/models", to: base)
    let constraints = try ProviderRequestConstraints(
      timeoutMilliseconds: 60_000,
      maximumResponseBytes: 16 * 1_024 * 1_024,
      maximumRetryAttempts: 1
    )
    let response = try await transport.send(
      ProviderWireValidation.makeJSONRequest(
        url: endpoint,
        method: "GET",
        headers: ["x-goog-api-key": key],
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
    let root = try ProviderWireValidation.decodeJSON(
      response.body,
      field: "Gemini model catalog JSON"
    )
    guard let values = root["models"]?.arrayValue else {
      throw ProviderFailure(
        code: .malformedResponse, message: "Gemini model catalog is missing models")
    }
    var models: [ProviderModelDescriptor] = []
    models.reserveCapacity(values.count)
    var seen = Set<ProviderModelID>()
    for (index, value) in values.enumerated() {
      guard value.objectValue != nil, let rawName = value["name"]?.stringValue else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini model entry \(index) has no valid name"
        )
      }
      let rawID =
        rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
      guard let id = ProviderModelID(rawValue: rawID) else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Gemini model entry \(index) has an invalid identifier"
        )
      }
      guard seen.insert(id).inserted else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini model catalog contains duplicate identifiers")
      }
      let displayName: String?
      if let value = value["displayName"] {
        if case .null = value {
          displayName = nil
        } else if let string = value.stringValue {
          displayName = string
        } else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "Gemini model entry \(index) has an invalid displayName")
        }
      } else {
        displayName = nil
      }
      let inputLimit: Int?
      if let value = value["inputTokenLimit"] {
        guard let integer = value.integerValue, integer > 0 else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "Gemini model entry \(index) has an invalid inputTokenLimit")
        }
        inputLimit = integer
      } else {
        inputLimit = nil
      }
      let outputLimit: Int?
      if let value = value["outputTokenLimit"] {
        guard let integer = value.integerValue, integer > 0 else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "Gemini model entry \(index) has an invalid outputTokenLimit")
        }
        outputLimit = integer
      } else {
        outputLimit = nil
      }
      models.append(
        try ProviderModelDescriptor(
          id: id,
          displayName: displayName == rawID ? nil : displayName,
          capabilities: capabilities,
          contextTokenLimit: inputLimit,
          maximumOutputTokens: outputLimit
        )
      )
    }
    return try ProviderModelCatalogResult(models: models, refreshedAt: await clock.now())
  }

  private var capabilities: ProviderCapabilities {
    ProviderDescriptorFactory.capabilities(
      structured: .declared(.providerDocumentation),
      reasoning: .declared(.providerDocumentation)
    )
  }

  private func encodeRequest(_ request: ProviderTurnRequest) throws -> ProviderJSONValue {
    try ProviderWireValidation.requireServerSideContinuationOptIn(request)
    if request.messages.contains(where: { message in
      message.content.contains { content in
        if case .toolCall = content { return true }
        return false
      }
    }) {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Gemini caller-owned tool history is not qualified without every provider step"
      )
    }
    var system: [String] = []
    var input: [ProviderJSONValue] = []

    for message in request.messages {
      if message.role == .system || message.role == .developer {
        system.append(
          contentsOf: message.content.compactMap { content in
            guard case .text(let value) = content else { return nil }
            return value
          })
        continue
      }
      if message.role == .tool {
        for content in message.content {
          guard case .toolResult(let callID, let name, let value, let isError) = content else {
            continue
          }
          let result: [String: ProviderJSONValue] = [
            "content": [
              [
                "type": "text",
                "text": .string(String(decoding: try value.encodedData(), as: UTF8.self)),
              ]
            ]
          ]
          var functionResult: [String: ProviderJSONValue] = [
            "type": "function_result",
            "name": .string(name),
            "call_id": .string(callID),
            "result": .object(result),
          ]
          if isError { functionResult["is_error"] = .bool(true) }
          input.append(.object(functionResult))
        }
        continue
      }
      let content = message.content.compactMap { item -> ProviderJSONValue? in
        guard case .text(let value) = item else { return nil }
        return ["type": "text", "text": .string(value)]
      }
      guard !content.isEmpty else { continue }
      input.append([
        "type": message.role == .assistant ? "model_output" : "user_input",
        "content": .array(content),
      ])
    }

    var body: [String: ProviderJSONValue] = [
      "model": .string(request.selection.modelID.rawValue),
      "input": .array(input),
      "stream": true,
      "store": .bool(ProviderWireValidation.storesServerSideResponse(request)),
    ]
    if !system.isEmpty {
      body["system_instruction"] = .string(system.joined(separator: "\n\n"))
    }
    if let continuation = request.continuation {
      body["previous_interaction_id"] = .string(continuation.value)
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          [
            "type": "function",
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.inputSchema,
          ]
        })
      guard request.toolChoice == .automatic else {
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "explicit Gemini tool choice is not qualified for the Interactions dialect"
        )
      }
      body["tool_choice"] = "auto"
    }
    switch request.output {
    case .text:
      break
    case .applicationValidatedJSON(_, let schema):
      body["response_format"] = [
        "type": "text",
        "mime_type": "application/json",
        "schema": schema,
      ]
    case .jsonSchema(_, let schema, let strict):
      guard strict else {
        throw ProviderFailure(
          code: .capabilityMismatch,
          message: "Gemini structured output requires a strict schema contract"
        )
      }
      body["response_format"] = [
        "type": "text",
        "mime_type": "application/json",
        "schema": schema,
      ]
    }
    var generationConfig: [String: ProviderJSONValue] = [:]
    if let maximumOutputTokens = request.constraints.maximumOutputTokens {
      generationConfig["max_output_tokens"] = .number(Double(maximumOutputTokens))
    }
    switch request.reasoning {
    case .disabled:
      generationConfig["thinking_level"] = "minimal"
    case .automatic:
      break
    case .effort(let effort):
      generationConfig["thinking_level"] = .string(effort.rawValue)
      generationConfig["thinking_summaries"] = "auto"
    }
    if !generationConfig.isEmpty { body["generation_config"] = .object(generationConfig) }
    return .object(body)
  }
}

private final class GeminiInteractionsStreamDecoder: ProviderStreamDecoder {
  private struct ToolState {
    let id: String
    let name: String
    let initialArguments: ProviderJSONValue?
    var arguments = ProviderToolArgumentAccumulator()
  }

  private enum StepState {
    case modelOutput
    case thought
    case functionCall(ToolState)
    case ignored
  }

  private let selection: ProviderSelection
  private let exposesContinuation: Bool
  private let allowsDisplayableReasoning: Bool
  private var responseID: String?
  private var steps: [Int: StepState] = [:]
  private var completion: ProviderCompletionDraft?
  private var emittedToolCount = 0
  private var sawDone = false

  init(
    selection: ProviderSelection,
    exposesContinuation: Bool,
    allowsDisplayableReasoning: Bool
  ) {
    self.selection = selection
    self.exposesContinuation = exposesContinuation
    self.allowsDisplayableReasoning = allowsDisplayableReasoning
  }

  func consume(_ event: ServerSentEvent) throws -> [ProviderDecodedEvent] {
    if event.data == "[DONE]" {
      sawDone = true
      return []
    }
    let root = try ProviderWireValidation.decodeJSON(
      Data(event.data.utf8),
      field: "Gemini stream JSON"
    )
    let type = root["event_type"]?.stringValue ?? event.event
    switch type {
    case "interaction.created":
      responseID = root.value(at: "interaction", "id")?.stringValue
      return []
    case "interaction.status_update":
      return []
    case "step.start":
      guard let index = root["index"]?.integerValue, index >= 0,
        let type = root.value(at: "step", "type")?.stringValue,
        !type.isEmpty,
        type.utf8.count <= 128,
        !type.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ProviderFailure(code: .malformedResponse, message: "Gemini step start is incomplete")
      }
      guard steps[index] == nil else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Gemini stream duplicated an active step")
      }
      if type == "function_call" {
        guard let id = root.value(at: "step", "id")?.stringValue,
          let name = root.value(at: "step", "name")?.stringValue
        else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Gemini function-call step is incomplete")
        }
        let initialArguments: ProviderJSONValue?
        if let arguments = root.value(at: "step", "arguments") {
          guard arguments.objectValue != nil else {
            throw ProviderFailure(
              code: .malformedResponse,
              message: "Gemini function-call arguments are not an object"
            )
          }
          initialArguments = arguments
        } else {
          initialArguments = nil
        }
        steps[index] = .functionCall(
          ToolState(id: id, name: name, initialArguments: initialArguments)
        )
        return []
      } else if type == "model_output" {
        steps[index] = .modelOutput
        return try initialModelOutput(root.value(at: "step", "content"))
      } else if type == "thought" {
        steps[index] = .thought
        return []
      } else {
        steps[index] = .ignored
        return []
      }
    case "step.delta":
      guard let index = root["index"]?.integerValue, index >= 0,
        let step = steps[index]
      else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Gemini step delta has no active step")
      }
      if case .ignored = step { return [] }
      switch root.value(at: "delta", "type")?.stringValue {
      case "text":
        switch step {
        case .thought:
          // Raw thought text is not a displayable summary. It can carry
          // provider-private reasoning, so never surface it to callers.
          return []
        case .modelOutput:
          break
        case .functionCall, .ignored:
          throw ProviderFailure(
            code: .malformedResponse, message: "Gemini text delta belongs to a non-output step")
        }
        guard let text = root.value(at: "delta", "text")?.stringValue, !text.isEmpty else {
          return []
        }
        return [.textDelta(text)]
      case "arguments_delta":
        guard case .functionCall(var tool) = step,
          let chunk = root.value(at: "delta", "arguments")?.stringValue
        else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Gemini arguments delta has no active function call")
        }
        try tool.arguments.append(chunk)
        steps[index] = .functionCall(tool)
        return []
      case "thought_summary":
        guard case .thought = step else {
          throw ProviderFailure(
            code: .malformedResponse,
            message: "Gemini thought summary belongs to a non-thought step")
        }
        guard allowsDisplayableReasoning else { return [] }
        guard let text = root.value(at: "delta", "content", "text")?.stringValue,
          !text.isEmpty
        else { return [] }
        return [.reasoningDelta(text)]
      default:
        return []
      }
    case "step.stop":
      guard let index = root["index"]?.integerValue, index >= 0,
        let step = steps.removeValue(forKey: index)
      else {
        throw ProviderFailure(
          code: .malformedResponse, message: "Gemini stream stopped an unknown step")
      }
      guard case .functionCall(let tool) = step else { return [] }
      let arguments =
        tool.arguments.byteCount == 0
        ? (tool.initialArguments ?? ProviderJSONValue.object([:]))
        : try tool.arguments.decodeObject()
      emittedToolCount += 1
      return [.toolCall(try ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments))]
    case "interaction.completed":
      guard completion == nil else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini stream emitted duplicate interaction.completed"
        )
      }
      guard steps.isEmpty else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini stream ended with an incomplete step"
        )
      }
      let interaction = root["interaction"]
      let identifier = interaction?["id"]?.stringValue ?? responseID
      responseID = identifier
      let status = interaction?["status"]?.stringValue
      switch status {
      case "completed":
        break
      case "requires_action":
        guard emittedToolCount > 0 else {
          throw ProviderFailure(
            code: .malformedResponse, message: "Gemini requires_action had no function call")
        }
      case "failed", "incomplete", "budget_exceeded":
        throw ProviderFailure(
          code: .serverFailed, message: "Gemini interaction ended unsuccessfully")
      case "cancelled":
        throw ProviderFailure(code: .cancelled, message: "Gemini interaction was cancelled")
      case "queued", "in_progress":
        throw ProviderFailure(
          code: .malformedResponse, message: "Gemini emitted a nonterminal status as completion")
      default:
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini interaction ended with an unsupported status")
      }
      let usage = try parseUsage(interaction?["usage"])
      let continuation: ProviderContinuation?
      if exposesContinuation, let identifier {
        continuation = try ProviderContinuation(
          providerID: selection.providerID,
          accountID: selection.accountID,
          value: identifier
        )
      } else {
        continuation = nil
      }
      let value = ProviderCompletionDraft(
        responseID: identifier,
        continuation: continuation,
        usage: usage
      )
      completion = value
      return [.completed(value)]
    case "error":
      throw ProviderFailure(
        code: .serverFailed,
        message: "Gemini stream failed"
      )
    case .none:
      throw ProviderFailure(code: .malformedResponse, message: "Gemini SSE event has no type")
    default:
      return []
    }
  }

  private func initialModelOutput(
    _ content: ProviderJSONValue?
  ) throws -> [ProviderDecodedEvent] {
    guard let content else { return [] }
    guard let items = content.arrayValue else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "Gemini model-output content is not an array"
      )
    }
    return try items.compactMap { item in
      guard item.objectValue != nil else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini model-output content item is not an object"
        )
      }
      guard item["type"]?.stringValue == "text" else { return nil }
      guard let text = item["text"]?.stringValue else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Gemini text content has no text value"
        )
      }
      return text.isEmpty ? nil : .textDelta(text)
    }
  }

  func finish() throws -> [ProviderDecodedEvent] {
    guard completion != nil else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: sawDone
          ? "Gemini stream emitted done before interaction.completed"
          : "Gemini stream ended before interaction.completed"
      )
    }
    return []
  }

  private func parseUsage(_ value: ProviderJSONValue?) throws -> ProviderUsage? {
    guard let value else { return nil }
    let object = try ProviderWireValidation.object(value, field: "Gemini usage")
    return try ProviderUsage(
      inputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_input_tokens"],
        field: "Gemini input token count"
      ),
      outputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_output_tokens"],
        field: "Gemini output token count"
      ),
      cachedInputTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_cached_tokens"],
        field: "Gemini cached token count"
      ),
      totalTokens: ProviderWireValidation.optionalNonnegativeInteger(
        object["total_tokens"],
        field: "Gemini total token count"
      )
    )
  }
}
