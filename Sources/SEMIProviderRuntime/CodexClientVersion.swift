import Darwin
import Foundation
import SEMIProviderCore

/// Resolves the non-secret Codex protocol version without coupling the core provider model to an
/// application installation. A managed `version.json` next to `auth.json` remains authoritative;
/// the standard ChatGPT installation supplies it when that file is absent.
///
/// Resolution is async, bounded, and memoized on purpose. The installation probe runs a
/// subprocess, so doing it inline on the execution actor would block the deadline watcher and
/// cancellation for as long as that process took to answer.
package enum CodexClientVersion {
  package static let embeddedCodexURL = URL(
    fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
    isDirectory: false
  )
  private static let maximumVersionBytes = 64 * 1_024
  private static let maximumProcessOutputBytes = 16 * 1_024
  private static let probeTimeout: Duration = .seconds(5)
  private static let cache = ProbeCache()

  package static func resolve(
    authURL: URL,
    embeddedCodexURL: URL = embeddedCodexURL
  ) async throws -> String {
    // A managed file is authoritative and cheap, so it is always re-read and
    // never memoized: rotating it must take effect on the next turn.
    let versionURL = authURL.deletingLastPathComponent().appendingPathComponent("version.json")
    if try regularEntryExists(versionURL) {
      let data = try SecureRegularFileReader.read(versionURL, maximumBytes: maximumVersionBytes)
      let root = try ProviderJSONValue.decode(from: data)
      guard let version = root["latest_version"]?.stringValue, isValid(version) else {
        throw unavailable()
      }
      return version
    }
    return try await cache.version(of: embeddedCodexURL)
  }

  /// Memoizes the installation probe per executable. The embedded binary cannot
  /// change version while the host process runs, so after the first success no
  /// turn pays for a subprocess again.
  ///
  /// The probe is awaited inline rather than through a shared unstructured
  /// task. Sharing one task would make the wait uncancellable for every caller
  /// but the first, which is exactly what must not happen to a turn whose
  /// deadline expired. The cost is that simultaneous first calls may each probe
  /// once; the probe is idempotent, bounded, and only reachable before the first
  /// success.
  private actor ProbeCache {
    private var resolved: [String: String] = [:]

    func version(of executableURL: URL) async throws -> String {
      let key = executableURL.path
      if let version = resolved[key] { return version }
      let version = try await CodexClientVersion.probe(executableURL)
      resolved[key] = version
      return version
    }
  }

  private static func probe(_ executableURL: URL) async throws -> String {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw unavailable()
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw unavailable()
    }

    // The process is already running, so both the deadline and an outer
    // cancellation have something concrete to terminate. Terminating it closes
    // the pipe, which is what actually releases the blocking reader below.
    let deadline = Task {
      try? await Task.sleep(for: probeTimeout)
      process.terminateIfRunning()
    }
    defer {
      deadline.cancel()
      process.terminateIfRunning()
    }

    let output = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        // Blocking pipe reads and `waitUntilExit` never run on the cooperative
        // pool; starving it would stall unrelated turns.
        DispatchQueue.global(qos: .userInitiated).async {
          var data = Data()
          while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4 * 1_024),
            !chunk.isEmpty
          {
            guard chunk.count <= maximumProcessOutputBytes - data.count else {
              process.terminateIfRunning()
              process.waitUntilExit()
              continuation.resume(throwing: unavailable())
              return
            }
            data.append(chunk)
          }
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            continuation.resume(throwing: unavailable())
            return
          }
          continuation.resume(returning: data)
        }
      }
    } onCancel: {
      process.terminateIfRunning()
    }

    let fields = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, fields[0] == "codex-cli" else { throw unavailable() }
    let version = String(fields[1])
    guard isValid(version) else { throw unavailable() }
    return version
  }

  private static func regularEntryExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    if errno == ENOENT { return false }
    throw unavailable()
  }

  private static func isValid(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        switch byte {
        case 43, 45, 46, 48...57, 65...90, 95, 97...122: true
        default: false
        }
      }
  }

  private static func unavailable() -> ProviderFailure {
    ProviderFailure(
      code: .authenticationFailed,
      message:
        "Codex client version is unavailable; provide version.json beside auth.json or install ChatGPT"
    )
  }
}

extension Process {
  fileprivate func terminateIfRunning() {
    guard isRunning else { return }
    terminate()
  }
}
