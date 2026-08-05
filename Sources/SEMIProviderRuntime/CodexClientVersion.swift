import SEMIProviderCore

/// The `codex-cli` wire version implemented by this package.
///
/// This value is owned by the package. Resolving it never reads adjacent
/// metadata, searches an installation, or starts a subprocess: those host
/// dependencies make identical requests behave differently across machines.
/// Bump it only when the Codex endpoint requires a newer wire contract.
package enum CodexClientVersion {
  package static let declared = "0.144.1"

  package static func resolve() -> String { declared }
}
