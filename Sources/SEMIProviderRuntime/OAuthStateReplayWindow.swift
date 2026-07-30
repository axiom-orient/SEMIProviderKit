/// Bounded in-process replay ledger for OAuth state values. The authorization
/// server still enforces one-time codes and PKCE; this window prevents an
/// accidentally reused registration request from growing runtime memory without
/// bound.
struct OAuthStateReplayWindow: Sendable {
  private let capacity: Int
  private var values: Set<String> = []
  private var slots: [String?]
  private var cursor = 0

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.slots = Array(repeating: nil, count: capacity)
  }

  mutating func consume(_ state: String) -> Bool {
    guard !values.contains(state) else { return false }
    if let evicted = slots[cursor] {
      values.remove(evicted)
    }
    slots[cursor] = state
    values.insert(state)
    cursor = (cursor + 1) % capacity
    return true
  }

  var count: Int { values.count }
}
