import BlueprintDomain
import Foundation

public struct FilingProperty: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var name: String
  public var address: String
  public var tenantName: String
  public var sharedFixedAssetIDs: [EntityID]

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    name: String,
    address: String,
    tenantName: String,
    sharedFixedAssetIDs: [EntityID] = []
  ) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FilingError.missingName
    }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.name = name
    self.address = address
    self.tenantName = tenantName
    self.sharedFixedAssetIDs = sharedFixedAssetIDs
  }
}

public enum RentalLedgerEntryKind: String, Codable, CaseIterable, Sendable {
  case rentRevenue
  case expense
  case depreciation
}

public struct RentalLedgerEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var propertyID: EntityID?
  public var transactionDate: Date
  public var kind: RentalLedgerEntryKind
  public var description: String
  public var amount: Money
  public var evidenceDocumentID: EntityID?

  public var isCommonExpense: Bool { kind != .rentRevenue && propertyID == nil }

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    propertyID: EntityID?,
    transactionDate: Date,
    kind: RentalLedgerEntryKind,
    description: String,
    amount: Money,
    evidenceDocumentID: EntityID? = nil
  ) throws {
    guard amount.yen > 0 else { throw FilingError.invalidAmount }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.propertyID = propertyID
    self.transactionDate = transactionDate
    self.kind = kind
    self.description = description
    self.amount = amount
    self.evidenceDocumentID = evidenceDocumentID
  }
}

public struct PropertyIncomeReport: Equatable, Sendable {
  public let revenue: Money
  public let expenses: Money
  public let depreciation: Money
  public let income: Money

  public static func make(entries: [RentalLedgerEntry]) -> PropertyIncomeReport {
    let revenue = entries.filter { $0.kind == .rentRevenue }.reduce(Int64(0)) {
      $0 + $1.amount.yen
    }
    let depreciation = entries.filter { $0.kind == .depreciation }.reduce(Int64(0)) {
      $0 + $1.amount.yen
    }
    let expenses = entries.filter { $0.kind == .expense }.reduce(Int64(0)) {
      $0 + $1.amount.yen
    }
    return PropertyIncomeReport(
      revenue: Money(yen: revenue),
      expenses: Money(yen: expenses),
      depreciation: Money(yen: depreciation),
      income: Money(yen: revenue - expenses - depreciation)
    )
  }
}
