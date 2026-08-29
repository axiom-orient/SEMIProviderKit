import Foundation
import SEMIProviderCore

/// An actor-isolated credential store whose contents exist only in memory.
///
/// Use this store when process-lifetime credentials are sufficient. It performs
/// no persistent storage or user authorization prompts. Records and credential
/// material disappear when the store is released or the process exits.
public actor InMemoryProviderCredentialStore: ProviderCredentialStore {
  private struct StoredCredential: Sendable {
    let record: ProviderCredentialRecord
    let material: ProviderCredentialMaterial
  }

  private var credentials: [ProviderAccountID: StoredCredential] = [:]
  private var referenceGeneration: UInt64 = 0

  public init() {}

  public func stage(
    _ request: ProviderAccountRegistrationRequest,
    at date: Date
  ) throws -> ProviderCredentialRecord {
    guard credentials[request.accountID] == nil else {
      throw ProviderFailure(
        code: .invalidRequest,
        message: "provider account already exists"
      )
    }

    let record = ProviderCredentialRecord(
      reference: try nextReference(),
      accountID: request.accountID,
      providerID: request.providerID,
      label: request.label,
      source: request.credential.source,
      state: .staged,
      endpoint: request.endpoint,
      options: request.options,
      createdAt: date,
      updatedAt: date
    )
    try ProviderValueValidation.credentialRecord(record)
    credentials[request.accountID] = StoredCredential(
      record: record,
      material: request.credential
    )
    return record
  }

  public func activate(
    _ stagedRecord: ProviderCredentialRecord,
    at date: Date
  ) throws {
    guard let stored = credentials[stagedRecord.accountID],
      stored.record == stagedRecord,
      stagedRecord.state == .staged
    else {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "staged credential identity does not match stored state"
      )
    }

    let activeRecord = ProviderCredentialRecord(
      reference: stagedRecord.reference,
      accountID: stagedRecord.accountID,
      providerID: stagedRecord.providerID,
      label: stagedRecord.label,
      source: stagedRecord.source,
      state: .active,
      endpoint: stagedRecord.endpoint,
      options: stagedRecord.options,
      createdAt: stagedRecord.createdAt,
      updatedAt: date
    )
    try ProviderValueValidation.credentialRecord(activeRecord)
    credentials[stagedRecord.accountID] = StoredCredential(
      record: activeRecord,
      material: stored.material
    )
  }

  /// Removal is idempotent. A matching reference may remove either the staged
  /// or activated form so registration compensation remains valid if
  /// activation succeeded but its read-back failed.
  public func remove(_ record: ProviderCredentialRecord) throws {
    guard let stored = credentials[record.accountID] else { return }
    guard stored.record.reference == record.reference else {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential identity does not match stored state"
      )
    }
    credentials.removeValue(forKey: record.accountID)
  }

  public func record(
    accountID: ProviderAccountID
  ) -> ProviderCredentialRecord? {
    credentials[accountID]?.record
  }

  public func lease(
    accountID: ProviderAccountID
  ) throws -> ProviderCredentialLease {
    guard let stored = credentials[accountID],
      stored.record.state == .active
    else {
      throw ProviderFailure(
        code: .accountUnavailable,
        message: "provider account is unavailable"
      )
    }
    return ProviderCredentialLease(record: stored.record, material: stored.material)
  }

  public func records() -> [ProviderCredentialRecord] {
    credentials.values.map(\.record)
  }

  private func nextReference() throws -> ProviderCredentialReference {
    let (next, overflowed) = referenceGeneration.addingReportingOverflow(1)
    guard !overflowed else {
      throw ProviderFailure(
        code: .internalInvariant,
        message: "in-memory credential reference generation exhausted"
      )
    }
    referenceGeneration = next
    return try ProviderCredentialReference("memory-\(next)")
  }
}
