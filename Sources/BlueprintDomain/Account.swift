import Foundation

public enum BalanceDirection: String, Codable, CaseIterable, Sendable {
  case debit
  case credit
}

public enum AccountCategory: String, Codable, CaseIterable, Sendable {
  case asset
  case liability
  case equity
  case revenue
  case expense
}

public enum StatementSection: String, Codable, CaseIterable, Sendable {
  case balanceSheetAsset
  case balanceSheetLiability
  case balanceSheetEquity
  case incomeStatementRevenue
  case incomeStatementExpense
}

public struct Account: Codable, Equatable, Sendable, Identifiable {
  public var metadata: EntityMetadata
  public var code: String
  public var name: String
  public var category: AccountCategory
  public var normalBalance: BalanceDirection
  public var defaultTaxRate: TaxRate
  public var statementSection: StatementSection
  public var displayOrder: Int
  public var isActive: Bool
  public var isSystem: Bool

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    code: String,
    name: String,
    category: AccountCategory,
    normalBalance: BalanceDirection,
    defaultTaxRate: TaxRate,
    statementSection: StatementSection,
    displayOrder: Int,
    isActive: Bool = true,
    isSystem: Bool = false
  ) {
    self.metadata = metadata
    self.code = code
    self.name = name
    self.category = category
    self.normalBalance = normalBalance
    self.defaultTaxRate = defaultTaxRate
    self.statementSection = statementSection
    self.displayOrder = displayOrder
    self.isActive = isActive
    self.isSystem = isSystem
  }

  public mutating func deactivate(at date: Date) {
    isActive = false
    metadata.touch(at: date)
  }
}

public struct SubAccount: Codable, Equatable, Sendable, Identifiable {
  public var metadata: EntityMetadata
  public let accountID: EntityID
  public var code: String
  public var name: String
  public var displayOrder: Int
  public var isActive: Bool

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    accountID: EntityID,
    code: String,
    name: String,
    displayOrder: Int,
    isActive: Bool = true
  ) {
    self.metadata = metadata
    self.accountID = accountID
    self.code = code
    self.name = name
    self.displayOrder = displayOrder
    self.isActive = isActive
  }
}

public enum StandardChartOfAccounts {
  public static func accounts(createdAt: Date) -> [Account] {
    [
      make("1000", "現金", .asset, .debit, .outOfScope, .balanceSheetAsset, 10, createdAt),
      make("1100", "普通預金", .asset, .debit, .outOfScope, .balanceSheetAsset, 20, createdAt),
      make("1200", "売掛金", .asset, .debit, .outOfScope, .balanceSheetAsset, 30, createdAt),
      make("2000", "未払金", .liability, .credit, .outOfScope, .balanceSheetLiability, 40, createdAt),
      make("2100", "買掛金", .liability, .credit, .outOfScope, .balanceSheetLiability, 50, createdAt),
      make("3000", "元入金", .equity, .credit, .outOfScope, .balanceSheetEquity, 60, createdAt),
      make("3100", "事業主貸", .equity, .debit, .outOfScope, .balanceSheetEquity, 70, createdAt),
      make("3200", "事業主借", .equity, .credit, .outOfScope, .balanceSheetEquity, 80, createdAt),
      make("4000", "売上高", .revenue, .credit, .standard10, .incomeStatementRevenue, 90, createdAt),
      make("5000", "仕入高", .expense, .debit, .standard10, .incomeStatementExpense, 100, createdAt),
      make("5100", "外注工賃", .expense, .debit, .standard10, .incomeStatementExpense, 110, createdAt),
      make("5200", "消耗品費", .expense, .debit, .standard10, .incomeStatementExpense, 120, createdAt),
      make("5300", "通信費", .expense, .debit, .standard10, .incomeStatementExpense, 130, createdAt),
      make("5400", "旅費交通費", .expense, .debit, .standard10, .incomeStatementExpense, 140, createdAt),
      make("5500", "支払手数料", .expense, .debit, .standard10, .incomeStatementExpense, 150, createdAt),
    ]
  }

  private static func make(
    _ code: String,
    _ name: String,
    _ category: AccountCategory,
    _ normalBalance: BalanceDirection,
    _ taxRate: TaxRate,
    _ section: StatementSection,
    _ order: Int,
    _ date: Date
  ) -> Account {
    Account(
      metadata: EntityMetadata(id: deterministicID(for: code), createdAt: date),
      code: code,
      name: name,
      category: category,
      normalBalance: normalBalance,
      defaultTaxRate: taxRate,
      statementSection: section,
      displayOrder: order,
      isSystem: true
    )
  }

  private static func deterministicID(for code: String) -> UUID {
    let padded = String(repeating: "0", count: max(0, 12 - code.count)) + code
    return UUID(uuidString: "B10E0000-0000-4000-8000-\(padded)")!
  }
}
