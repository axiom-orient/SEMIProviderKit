import Foundation
import SEMIProviderCore

package enum ProviderCredentialContract {
  static func validate(records: [ProviderCredentialRecord]) throws {
    do {
      try ProviderValueValidation.credentialRecords(records)
    } catch {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential vault returned an invalid record set"
      )
    }
  }

  static func validate(
    lease: ProviderCredentialLease,
    expectedAccountID: ProviderAccountID,
    expectedProviderID: ProviderID? = nil,
    requiresActiveRecord: Bool = true
  ) throws -> ProviderCredentialLease {
    do {
      try ProviderValueValidation.credentialLease(
        lease,
        requiresActiveRecord: requiresActiveRecord
      )
    } catch {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential vault returned an invalid lease"
      )
    }
    guard lease.record.accountID == expectedAccountID else {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential vault returned a lease for a different account"
      )
    }
    if let expectedProviderID, lease.record.providerID != expectedProviderID {
      throw ProviderFailure(
        code: .accountUnavailable,
        message: "provider account does not belong to the selected provider"
      )
    }
    return lease
  }

  static func validateActivated(
    lease: ProviderCredentialLease,
    stagedRecord: ProviderCredentialRecord
  ) throws -> ProviderCredentialLease {
    let lease = try validate(
      lease: lease,
      expectedAccountID: stagedRecord.accountID,
      expectedProviderID: stagedRecord.providerID
    )
    let active = lease.record
    guard active.reference == stagedRecord.reference,
      active.label == stagedRecord.label,
      active.source == stagedRecord.source,
      active.endpoint == stagedRecord.endpoint,
      active.createdAt == stagedRecord.createdAt
    else {
      throw ProviderFailure(
        code: .credentialRecoveryRequired,
        message: "credential activation read-back did not match the staged record"
      )
    }
    return lease
  }
}
