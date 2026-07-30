import Foundation
import SEMIProviderCore

package struct OpenAIResponsesAdapter: ProviderAdapter {
  package enum Kind: Equatable, Sendable {
    case soa
    case openAI
  }

  package let kind: Kind

  package var descriptor: ProviderDescriptor {
    switch kind {
    case .soa:
      ProviderDescriptorFactory.make(
        id: BuiltInProviderID.soa,
        name: "Soa (ChatGPT subscription)",
        family: .soaResponses,
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
    let endpoint: URL
    let headers: [String: String]
    switch kind {
    case .soa:
      let auth = try await SoaCredentialResolver.resolve(credential.material)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.soa
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
    OpenAIResponsesStreamDecoder(selection: request.selection)
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
    case .soa:
      let auth = try await SoaCredentialResolver.resolve(credential.material)
      let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.soa
      var components = URLComponents(
        url: try ProviderWireValidation.appendPath("/models", to: base),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [URLQueryItem(name: "client_version", value: auth.clientVersion)]
      guard let url = components?.url else {
        throw ProviderFailure(code: .invalidRequest, message: "Soa model URL is invalid")
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
    var input: [ProviderJSONValue] = []
    var instructions: [String] = []
    for message in request.messages {
      if kind == .soa, message.role == .system || message.role == .developer {
        instructions.append(contentsOf: message.content.compactMap(\.textValue))
        continue
      }
      if message.role == .tool {
        for content in message.content {
          guard case .toolResult(let callID, _, let value) = content else { continue }
          input.append([
            "type": "function_call_output",
            "call_id": .string(callID),
            "output": .string(String(decoding: try value.encodedData(), as: UTF8.self)),
          ])
        }
        continue
      }
      let contentType = message.role == .assistant ? "output_text" : "input_text"
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
      "store": false,
    ]
    if let maximumOutputTokens = request.constraints.maximumOutputTokens {
      body["max_output_tokens"] = .number(Double(maximumOutputTokens))
    }
    if kind == .soa { body["instructions"] = .string(instructions.joined(separator: "\n\n")) }
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
}

extension ProviderMessageContent {
  fileprivate var textValue: String? {
    guard case .text(let text) = self else { return nil }
    return text
  }
}

private struct SoaResolvedCredential: Sendable {
  let accessToken: String
  let accountID: String
  let clientVersion: String
}

private enum SoaCredentialResolver {
  private static let maximumAuthBytes = 1 * 1_024 * 1_024

  static func resolve(_ material: ProviderCredentialMaterial) async throws -> SoaResolvedCredential
  {
    guard case .externalAuthFile(let path) = material else {
      throw ProviderFailure(
        code: .authenticationFailed, message: "Soa requires an external auth.json reference")
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
        message: "Soa auth.json does not contain supported ChatGPT credentials")
    }
    let accessToken: String
    do {
      accessToken = try SensitiveValue(rawAccessToken).revealed
    } catch {
      throw ProviderFailure(
        code: .authenticationFailed, message: "Soa auth.json contains an invalid access token")
    }
    let version = try await SoaCodexClientVersion.resolve(authURL: authURL)
    return .init(accessToken: accessToken, accountID: accountID, clientVersion: version)
  }

}

private final class OpenAIResponsesStreamDecoder: ProviderStreamDecoder, @unchecked Sendable {
  private struct ToolState {
    var callID: String?
    var name: String?
    var arguments = ProviderToolArgumentAccumulator()
    var emitted = false
  }

  private let selection: ProviderSelection
  private var responseID: String?
  private var usage: ProviderUsage?
  private var tools: [String: ToolState] = [:]
  private var completed = false

  init(selection: ProviderSelection) {
    self.selection = selection
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
      let key = try toolKey(root, fallbackIndex: tools.count)
      var state = tools[key] ?? ToolState()
      state.callID = root.value(at: "item", "call_id")?.stringValue ?? state.callID
      state.name = root.value(at: "item", "name")?.stringValue ?? state.name
      if let arguments = root.value(at: "item", "arguments")?.stringValue, !arguments.isEmpty {
        try state.arguments.replace(with: arguments)
      }
      tools[key] = state
      return []
    case "response.function_call_arguments.delta":
      let key = try toolKey(root, fallbackIndex: 0)
      var state = tools[key] ?? ToolState()
      if let delta = root["delta"]?.stringValue { try state.arguments.append(delta) }
      tools[key] = state
      return []
    case "response.function_call_arguments.done":
      let key = try toolKey(root, fallbackIndex: 0)
      var state = tools[key] ?? ToolState()
      if let arguments = root["arguments"]?.stringValue {
        try state.arguments.replace(with: arguments)
      }
      tools[key] = state
      return try emitTool(key: key)
    case "response.output_item.done":
      guard root.value(at: "item", "type")?.stringValue == "function_call" else { return [] }
      let key = try toolKey(root, fallbackIndex: 0)
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
      let continuation = try responseID.map {
        try ProviderContinuation(
          providerID: selection.providerID,
          accountID: selection.accountID,
          value: $0
        )
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

  private func toolKey(_ root: ProviderJSONValue, fallbackIndex: Int) throws -> String {
    if let value = root.value(at: "item", "id")?.stringValue ?? root["item_id"]?.stringValue {
      return value
    }
    let index = try ProviderWireValidation.nonnegativeInteger(
      root["output_index"],
      defaultValue: fallbackIndex,
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
