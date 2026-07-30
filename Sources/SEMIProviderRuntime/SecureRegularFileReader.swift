import Darwin
import Foundation
import SEMIProviderCore

package enum SecureRegularFileReader {
  package static func read(
    _ url: URL,
    maximumBytes: Int,
    failureCode: ProviderFailureCode = .authenticationFailed
  ) throws -> Data {
    guard url.isFileURL,
      maximumBytes >= 0,
      !url.path.isEmpty,
      !url.path.utf8.contains(0)
    else {
      throw failure(
        code: failureCode,
        message: "credential file path or byte limit is invalid"
      )
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw failure(
        code: failureCode,
        message: "credential file is missing, unsafe, or inaccessible"
      )
    }
    defer { _ = close(descriptor) }

    var initial = stat()
    guard fstat(descriptor, &initial) == 0,
      (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      initial.st_size >= 0,
      UInt64(initial.st_size) <= UInt64(maximumBytes)
    else {
      throw failure(
        code: failureCode,
        message: "credential file is not a bounded regular file"
      )
    }

    var result = Data()
    result.reserveCapacity(Int(initial.st_size))
    let chunkSize = 64 * 1_024
    var buffer = [UInt8](repeating: 0, count: chunkSize)

    while true {
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if bytesRead == 0 { break }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        throw failure(
          code: failureCode,
          message: "credential file could not be read"
        )
      }
      guard result.count <= maximumBytes - bytesRead else {
        throw failure(
          code: failureCode,
          message: "credential file exceeded its byte limit"
        )
      }
      result.append(contentsOf: buffer.prefix(bytesRead))
    }

    var final = stat()
    guard fstat(descriptor, &final) == 0,
      (final.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      initial.st_dev == final.st_dev,
      initial.st_ino == final.st_ino,
      initial.st_size == final.st_size,
      final.st_size == off_t(result.count)
    else {
      throw failure(
        code: failureCode,
        message: "credential file changed while it was being read"
      )
    }
    return result
  }

  private static func failure(code: ProviderFailureCode, message: String) -> ProviderFailure {
    ProviderFailure(code: code, message: message)
  }
}
