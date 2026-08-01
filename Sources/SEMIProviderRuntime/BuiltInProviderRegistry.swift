import Foundation
import SEMIProviderCore

package struct BuiltInProviderRegistry: Sendable {
  private let adapters: [ProviderID: any ProviderAdapter]

  package init() {
    let values: [any ProviderAdapter] = [
      OpenAIResponsesAdapter(kind: .codex),
      OpenAIResponsesAdapter(kind: .openAI),
      AnthropicMessagesAdapter(kind: .anthropic),
      GeminiInteractionsAdapter(),
      OpenAIChatAdapter(kind: .openRouter),
      OpenAIChatAdapter(kind: .deepSeek),
      OpenAIChatAdapter(kind: .qwen),
      OpenAIChatAdapter(kind: .kimi),
      OpenAIChatAdapter(kind: .zai),
      AnthropicMessagesAdapter(kind: .miniMax),
    ]
    self.adapters = Dictionary(uniqueKeysWithValues: values.map { ($0.descriptor.id, $0) })
  }

  package func descriptors() -> [ProviderDescriptor] {
    adapters.values.map(\.descriptor).sorted { $0.id.rawValue < $1.id.rawValue }
  }

  package func adapter(for id: ProviderID) throws -> any ProviderAdapter {
    guard let adapter = adapters[id] else {
      throw ProviderFailure(
        code: .providerUnsupported,
        message: "unsupported provider: \(id.rawValue)"
      )
    }
    return adapter
  }
}

package enum ProviderEndpointCatalog {
  package static let openAI = URL(string: "https://api.openai.com")!
  package static let codex = URL(string: "https://chatgpt.com/backend-api/codex")!
  package static let anthropic = URL(string: "https://api.anthropic.com")!
  package static let gemini = URL(string: "https://generativelanguage.googleapis.com")!
  package static let openRouter = URL(string: "https://openrouter.ai/api/v1")!
  package static let deepSeek = URL(string: "https://api.deepseek.com")!
  package static let kimi = URL(string: "https://api.moonshot.ai/v1")!
  package static let zai = URL(string: "https://api.z.ai/api/paas/v4")!
  package static let miniMax = URL(string: "https://api.minimax.io/anthropic")!
}

package enum ProviderDescriptorFactory {
  package static func make(
    id: ProviderID,
    name: String,
    family: ProviderProtocolFamily,
    apiKey: Bool,
    oauth: Bool = false,
    explicitEndpoint: Bool = false
  ) -> ProviderDescriptor {
    do {
      return try ProviderDescriptor(
        id: id,
        displayName: name,
        protocolFamily: family,
        supportsAPIKey: apiKey,
        supportsOAuth: oauth,
        requiresExplicitEndpoint: explicitEndpoint
      )
    } catch {
      preconditionFailure("invalid built-in provider descriptor: \(error)")
    }
  }

  package static func capabilities(
    structured: CapabilitySupport = .unknown,
    reasoning: CapabilitySupport = .unknown
  ) -> ProviderCapabilities {
    .init(
      streaming: .declared(.providerDocumentation),
      toolCalling: .declared(.providerDocumentation),
      parallelToolCalling: .unknown,
      structuredOutput: structured,
      reasoningContinuity: reasoning,
      usageReporting: .declared(.providerDocumentation)
    )
  }
}
