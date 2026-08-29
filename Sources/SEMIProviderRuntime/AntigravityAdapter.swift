import Foundation
import SEMIProviderCore

/// Google Cloud Code's Antigravity endpoint is a unary JSON dialect wrapped
/// around Gemini-style contents, not the public Gemini Interactions stream.
package struct AntigravityAdapter: ProviderAdapter {
  package init() {}

  package var descriptor: ProviderDescriptor {
    ProviderDescriptorFactory.make(
      id: BuiltInProviderID.antigravity,
      name: "Antigravity",
      family: .geminiCloudCode,
      apiKey: false
    )
  }

  package var responseFraming: ProviderResponseFraming { .unaryJSON }

  package func makeExecutionRequest(
    _ request: ProviderTurnRequest,
    credential: ProviderCredentialLease
  ) async throws -> ProviderHTTPRequest {
    guard request.continuation == nil else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Antigravity does not accept a Responses continuation"
      )
    }
    guard request.output == .text else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Antigravity does not declare structured output support"
      )
    }
    guard request.reasoning == .automatic else {
      throw ProviderFailure(
        code: .capabilityMismatch,
        message: "Antigravity does not declare reasoning controls"
      )
    }

    let token = try ProviderWireValidation.requireBearerToken(credential)
    let base = credential.record.endpoint?.baseURL ?? ProviderEndpointCatalog.antigravity
    guard let projectID = credential.record.options?.values["project-id"] else {
      throw ProviderFailure(
        code: .invalidRequest,
        message: "Antigravity requires a configured project ID"
      )
    }
    let endpoint = try ProviderWireValidation.appendPath("/v1internal:generateContent", to: base)
    let model = request.selection.modelID.rawValue
    let inner = try encodeRequest(request)
    let envelope: ProviderJSONValue = [
      "model": .string(model),
      "userAgent": "antigravity",
      "requestType": "agent",
      "project": .string(projectID),
      "requestId": .string("agent-\(request.id.rawValue)"),
      "request": inner,
    ]
    var headers = [
      "Authorization": "Bearer \(token)",
      "User-Agent": "SEMI/9.0.0 iOS",
      "X-Client-Name": "antigravity",
      "X-Client-Version": "1.107.0",
      "x-goog-api-client": "gl-node/18.18.2 fire/0.8.6 grpc/1.10.x",
      "Accept": "application/json",
    ]
    if model.lowercased().contains("claude"), model.lowercased().contains("thinking") {
      headers["anthropic-beta"] = "interleaved-thinking-2025-05-14"
    }
    return try ProviderWireValidation.makeJSONRequest(
      url: endpoint,
      headers: headers,
      body: envelope,
      constraints: request.constraints
    )
  }

  package func decodeUnaryResponse(
    _ data: Data,
    request: ProviderTurnRequest
  ) throws -> [ProviderDecodedEvent] {
    _ = request
    let root = try ProviderWireValidation.decodeJSON(data, field: "Antigravity response JSON")
    let response = root["response"] ?? root
    guard let candidate = response["candidates"]?.arrayValue?.first?.objectValue,
      let parts = candidate["content"]?["parts"]?.arrayValue
    else {
      throw ProviderFailure(
        code: .malformedResponse,
        message: "Antigravity response did not contain a candidate content"
      )
    }

    var text: [String] = []
    var calls: [ProviderToolCall] = []
    for (index, part) in parts.enumerated() {
      guard let object = part.objectValue else { continue }
      if let value = object["text"]?.stringValue, !value.isEmpty { text.append(value) }
      guard let function = object["functionCall"]?.objectValue else { continue }
      guard let name = function["name"]?.stringValue else {
        throw ProviderFailure(
          code: .malformedResponse,
          message: "Antigravity function call has no valid name"
        )
      }
      let arguments = function["args"] ?? .object([:])
      let identifier = function["id"]?.stringValue ?? "antigravity-\(index)-\(name)"
      calls.append(try ProviderToolCall(id: identifier, name: name, arguments: arguments))
    }

    var result: [ProviderDecodedEvent] = []
    let textValue = text.joined(separator: "\n")
    if !textValue.isEmpty { result.append(.textDelta(textValue)) }
    result.append(contentsOf: calls.map(ProviderDecodedEvent.toolCall))
    result.append(.completed(ProviderCompletionDraft()))
    return result
  }

  package func inspect(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderAccountInspection {
    _ = credential
    _ = transport
    _ = clock
    throw ProviderFailure(
      code: .capabilityMismatch,
      message: "Antigravity has no verified account-inspection endpoint"
    )
  }

  package func models(
    credential: ProviderCredentialLease,
    transport: any ProviderHTTPTransport,
    clock: any ProviderClock
  ) async throws -> ProviderModelCatalogResult {
    _ = credential
    _ = transport
    _ = clock
    throw ProviderFailure(
      code: .capabilityMismatch,
      message: "Antigravity model discovery is not qualified"
    )
  }

  private func encodeRequest(_ request: ProviderTurnRequest) throws -> ProviderJSONValue {
    var contents: [ProviderJSONValue] = []
    var system: [String] = []
    var pendingResults: [ProviderJSONValue] = []

    func flushResults() {
      guard !pendingResults.isEmpty else { return }
      contents.append(["role": "user", "parts": .array(pendingResults)])
      pendingResults.removeAll(keepingCapacity: true)
    }

    for message in request.messages {
      if message.role == .system || message.role == .developer {
        system.append(
          contentsOf: message.content.compactMap { item in
            guard case .text(let value) = item else { return nil }
            return value
          })
        continue
      }
      if message.role == .tool {
        for content in message.content {
          guard case .toolResult(let callID, let name, let value, let isError) = content else {
            continue
          }
          let response: ProviderJSONValue
          if let object = value.objectValue {
            response = .object(object)
          } else {
            response = [isError ? "error" : "result": value]
          }
          pendingResults.append([
            "functionResponse": [
              "name": .string(name),
              "id": .string(callID),
              "response": response,
            ]
          ])
        }
        continue
      }

      flushResults()
      var parts: [ProviderJSONValue] = []
      for content in message.content {
        switch content {
        case .text(let value): parts.append(["text": .string(value)])
        case .toolCall(let callID, let name, let arguments):
          parts.append([
            "functionCall": [
              "name": .string(name),
              "args": arguments,
              "id": .string(callID),
            ]
          ])
        case .toolResult:
          throw ProviderFailure(
            code: .internalInvariant,
            message: "tool result appeared outside a tool message"
          )
        }
      }
      guard !parts.isEmpty else { continue }
      contents.append([
        "role": .string(message.role == .assistant ? "model" : "user"),
        "parts": .array(parts),
      ])
    }
    flushResults()
    guard !contents.isEmpty else {
      throw ProviderFailure(code: .invalidRequest, message: "Antigravity request has no content")
    }

    var body: [String: ProviderJSONValue] = ["contents": .array(contents)]
    if !system.isEmpty {
      body["systemInstruction"] = ["parts": [["text": .string(system.joined(separator: "\n\n"))]]]
    }
    if !request.tools.isEmpty {
      body["tools"] = [
        [
          "functionDeclarations": .array(
            request.tools.map { tool in
              [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
              ]
            })
        ]
      ]
    }
    if let maximumOutputTokens = request.constraints.maximumOutputTokens {
      body["generationConfig"] = ["maxOutputTokens": .number(Double(maximumOutputTokens))]
    }
    return .object(body)
  }
}
