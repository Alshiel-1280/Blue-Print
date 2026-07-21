import BlueprintDomain
import Foundation

public enum ClosingAdjustmentError: Error, Equatable, Sendable {
  case invalidRate
  case invalidAmount
  case missingRequiredAccount
}

public struct HouseholdAllocationRule: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var name: String
  public var expenseAccountID: EntityID
  public var ownerDrawingsAccountID: EntityID
  public var personalBasisPoints: Int
  public var rationale: String

  public init(
    id: EntityID = UUID(),
    name: String,
    expenseAccountID: EntityID,
    ownerDrawingsAccountID: EntityID,
    personalBasisPoints: Int,
    rationale: String
  ) throws {
    guard (0...10_000).contains(personalBasisPoints) else {
      throw ClosingAdjustmentError.invalidRate
    }
    self.id = id
    self.name = name
    self.expenseAccountID = expenseAccountID
    self.ownerDrawingsAccountID = ownerDrawingsAccountID
    self.personalBasisPoints = personalBasisPoints
    self.rationale = rationale
  }

  public func adjustmentEntry(
    fiscalYear: FiscalYear,
    expenseBalance: Money,
    transactionDate: Date,
    at date: Date
  ) throws -> JournalEntry? {
    let personalAmount = expenseBalance.yen * Int64(personalBasisPoints) / 10_000
    guard personalAmount > 0 else { return nil }
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYear.id,
      transactionDate: transactionDate,
      description: "家事按分 \(name)",
      kind: .closing,
      lines: [
        try JournalLine(
          accountID: ownerDrawingsAccountID,
          side: .debit,
          amount: Money(yen: personalAmount),
          memo: "家事割合 \(personalBasisPoints)/10000 \(rationale)"
        ),
        try JournalLine(
          accountID: expenseAccountID,
          side: .credit,
          amount: Money(yen: personalAmount),
          memo: "家事按分"
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }
}

public struct InventoryClosing: Codable, Equatable, Sendable {
  public var openingInventory: Money
  public var purchases: Money
  public var closingInventory: Money

  public init(openingInventory: Money, purchases: Money, closingInventory: Money) throws {
    guard openingInventory.yen >= 0, purchases.yen >= 0, closingInventory.yen >= 0 else {
      throw ClosingAdjustmentError.invalidAmount
    }
    self.openingInventory = openingInventory
    self.purchases = purchases
    self.closingInventory = closingInventory
  }

  public var costOfGoodsSold: Money {
    Money(yen: openingInventory.yen + purchases.yen - closingInventory.yen)
  }

  public func closingEntry(
    fiscalYear: FiscalYear,
    inventoryAccountID: EntityID,
    purchasesAccountID: EntityID,
    transactionDate: Date,
    at date: Date
  ) throws -> JournalEntry? {
    let adjustment = closingInventory.yen - openingInventory.yen
    guard adjustment != 0 else { return nil }
    let increase = adjustment > 0
    let amount = Money(yen: abs(adjustment))
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYear.id,
      transactionDate: transactionDate,
      description: "期末棚卸振替",
      kind: .closing,
      lines: [
        try JournalLine(
          accountID: inventoryAccountID,
          side: increase ? .debit : .credit,
          amount: amount
        ),
        try JournalLine(
          accountID: purchasesAccountID,
          side: increase ? .credit : .debit,
          amount: amount
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }
}

public enum AccrualTemplateKind: String, Codable, CaseIterable, Sendable {
  case accruedRevenue
  case accruedExpense
  case prepaidExpense
  case deferredRevenue
}

public struct AccrualTemplate: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var name: String
  public var kind: AccrualTemplateKind
  public var debitAccountID: EntityID
  public var creditAccountID: EntityID
  public var description: String

  public init(
    id: EntityID = UUID(),
    name: String,
    kind: AccrualTemplateKind,
    debitAccountID: EntityID,
    creditAccountID: EntityID,
    description: String
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.debitAccountID = debitAccountID
    self.creditAccountID = creditAccountID
    self.description = description
  }

  public func entry(
    fiscalYear: FiscalYear,
    amount: Money,
    transactionDate: Date,
    at date: Date
  ) throws -> JournalEntry {
    guard amount.yen > 0 else { throw ClosingAdjustmentError.invalidAmount }
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYear.id,
      transactionDate: transactionDate,
      description: description,
      kind: .closing,
      lines: [
        try JournalLine(accountID: debitAccountID, side: .debit, amount: amount),
        try JournalLine(accountID: creditAccountID, side: .credit, amount: amount),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }

  public static func standard(accounts: [Account]) throws -> [AccrualTemplate] {
    func id(_ code: String) throws -> EntityID {
      guard let account = accounts.first(where: { $0.code == code }) else {
        throw ClosingAdjustmentError.missingRequiredAccount
      }
      return account.id
    }
    return [
      AccrualTemplate(
        name: "未収収益", kind: .accruedRevenue, debitAccountID: try id("1250"),
        creditAccountID: try id("4000"), description: "未収収益の計上"),
      AccrualTemplate(
        name: "未払費用", kind: .accruedExpense, debitAccountID: try id("5100"),
        creditAccountID: try id("2300"), description: "未払費用の計上"),
      AccrualTemplate(
        name: "前払費用", kind: .prepaidExpense, debitAccountID: try id("1400"),
        creditAccountID: try id("5100"), description: "前払費用への振替"),
      AccrualTemplate(
        name: "前受収益", kind: .deferredRevenue, debitAccountID: try id("4000"),
        creditAccountID: try id("2200"), description: "前受収益への振替"),
    ]
  }
}

public enum ClosingCheckSeverity: String, Codable, CaseIterable, Sendable {
  case blocking
  case warning
  case information
}

public struct ClosingCheckItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let severity: ClosingCheckSeverity
  public let isResolved: Bool

  public init(
    id: String,
    title: String,
    detail: String,
    severity: ClosingCheckSeverity,
    isResolved: Bool
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.severity = severity
    self.isResolved = isResolved
  }
}

public struct ClosingChecklist: Codable, Equatable, Sendable {
  public let items: [ClosingCheckItem]

  public init(items: [ClosingCheckItem]) {
    self.items = items
  }

  public var unresolvedItems: [ClosingCheckItem] { items.filter { !$0.isResolved } }
  public var canFinalize: Bool {
    !items.contains { !$0.isResolved && $0.severity == .blocking }
  }
  public var finalizeWarning: String? {
    guard !unresolvedItems.isEmpty else { return nil }
    return "未解決の決算確認が\(unresolvedItems.count)件あります。内容を確認してから年度を確定してください。"
  }
}
