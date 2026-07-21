import Foundation

public enum FiscalYearStatus: String, Codable, CaseIterable, Sendable {
  case open
  case closing
  case filed
  case locked
}

public enum FiscalYearError: Error, Equatable, Sendable {
  case unsupportedCalendarYear(Int)
  case missingReopenReason
}

public struct FiscalYear: Codable, Equatable, Sendable, Identifiable {
  public var metadata: EntityMetadata
  public let calendarYear: Int
  public var status: FiscalYearStatus
  public var taxRuleSetID: String
  public var formRuleSetID: String
  public var lockedAt: Date?

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    calendarYear: Int,
    status: FiscalYearStatus = .open,
    taxRuleSetID: String,
    formRuleSetID: String,
    lockedAt: Date? = nil
  ) throws {
    guard (2000...2100).contains(calendarYear) else {
      throw FiscalYearError.unsupportedCalendarYear(calendarYear)
    }
    self.metadata = metadata
    self.calendarYear = calendarYear
    self.status = status
    self.taxRuleSetID = taxRuleSetID
    self.formRuleSetID = formRuleSetID
    self.lockedAt = lockedAt
  }

  public mutating func lock(at date: Date) {
    status = .locked
    lockedAt = date
    metadata.touch(at: date)
  }

  public mutating func reopen(reason: String, at date: Date) throws {
    guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FiscalYearError.missingReopenReason
    }
    status = .open
    lockedAt = nil
    metadata.touch(at: date)
  }
}
