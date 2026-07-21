import BlueprintDomain
import BlueprintFiling
import Foundation

public final class SQLiteFilingRepository: FilingRepository, @unchecked Sendable {
  private let connection: SQLiteConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveWorkspace(_ workspace: FilingWorkspace) throws {
    try connection.execute(
      """
      INSERT INTO filing_workspaces(id, fiscal_year_id, payload_json) VALUES (?,?,?)
      ON CONFLICT(fiscal_year_id) DO UPDATE SET
          id = excluded.id, payload_json = excluded.payload_json
      """,
      bindings: rowBindings(workspace.id, workspace.fiscalYearID, workspace)
    )
  }

  public func workspace(fiscalYearID: EntityID) throws -> FilingWorkspace? {
    try fetchOne(FilingWorkspace.self, table: "filing_workspaces", fiscalYearID: fiscalYearID)
  }

  public func saveWage(_ wage: WageWithholdingStatement) throws {
    try save(wage, id: wage.id, fiscalYearID: wage.fiscalYearID, table: "wage_statements")
  }

  public func wages(fiscalYearID: EntityID) throws -> [WageWithholdingStatement] {
    try fetch(WageWithholdingStatement.self, table: "wage_statements", fiscalYearID: fiscalYearID)
  }

  public func saveProperty(_ property: FilingProperty) throws {
    try save(
      property, id: property.id, fiscalYearID: property.fiscalYearID, table: "filing_properties")
  }

  public func properties(fiscalYearID: EntityID) throws -> [FilingProperty] {
    try fetch(FilingProperty.self, table: "filing_properties", fiscalYearID: fiscalYearID)
  }

  public func saveRentalEntry(_ entry: RentalLedgerEntry) throws {
    try save(
      entry, id: entry.id, fiscalYearID: entry.fiscalYearID, table: "rental_ledger_entries")
  }

  public func rentalEntries(fiscalYearID: EntityID) throws -> [RentalLedgerEntry] {
    try fetch(RentalLedgerEntry.self, table: "rental_ledger_entries", fiscalYearID: fiscalYearID)
  }

  public func saveSecuritiesReport(_ report: SecuritiesAnnualReport) throws {
    try save(
      report, id: report.id, fiscalYearID: report.fiscalYearID,
      table: "securities_annual_reports")
  }

  public func securitiesReports(fiscalYearID: EntityID) throws -> [SecuritiesAnnualReport] {
    try fetch(
      SecuritiesAnnualReport.self, table: "securities_annual_reports", fiscalYearID: fiscalYearID)
  }

  public func saveLossCarryforward(_ carryforward: StockLossCarryforward) throws {
    try save(
      carryforward, id: carryforward.id, fiscalYearID: carryforward.fiscalYearID,
      table: "stock_loss_carryforwards")
  }

  public func lossCarryforwards(fiscalYearID: EntityID) throws -> [StockLossCarryforward] {
    try fetch(
      StockLossCarryforward.self, table: "stock_loss_carryforwards", fiscalYearID: fiscalYearID)
  }

  public func saveOtherIncome(_ income: OtherIncomeEntry) throws {
    try save(
      income, id: income.id, fiscalYearID: income.fiscalYearID, table: "other_income_entries")
  }

  public func otherIncome(fiscalYearID: EntityID) throws -> [OtherIncomeEntry] {
    try fetch(OtherIncomeEntry.self, table: "other_income_entries", fiscalYearID: fiscalYearID)
  }

  public func saveDeduction(_ deduction: FilingDeduction) throws {
    try save(
      deduction, id: deduction.id, fiscalYearID: deduction.fiscalYearID,
      table: "filing_deductions")
  }

  public func deductions(fiscalYearID: EntityID) throws -> [FilingDeduction] {
    try fetch(FilingDeduction.self, table: "filing_deductions", fiscalYearID: fiscalYearID)
  }

  public func saveUnsupportedCase(_ unsupportedCase: UnsupportedFilingCase) throws {
    try save(
      unsupportedCase, id: unsupportedCase.id, fiscalYearID: unsupportedCase.fiscalYearID,
      table: "unsupported_filing_cases")
  }

  public func unsupportedCases(fiscalYearID: EntityID) throws -> [UnsupportedFilingCase] {
    try fetch(
      UnsupportedFilingCase.self, table: "unsupported_filing_cases", fiscalYearID: fiscalYearID)
  }

  private func save<T: Encodable>(
    _ value: T, id: EntityID, fiscalYearID: EntityID, table: String
  ) throws {
    try connection.execute(
      """
      INSERT INTO \(table)(id, fiscal_year_id, payload_json) VALUES (?,?,?)
      ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json
      """,
      bindings: rowBindings(id, fiscalYearID, value)
    )
  }

  private func fetch<T: Decodable>(
    _ type: T.Type, table: String, fiscalYearID: EntityID
  ) throws -> [T] {
    try connection.query(
      "SELECT payload_json FROM \(table) WHERE fiscal_year_id = ? ORDER BY rowid",
      bindings: [.text(fiscalYearID.filingDatabaseString)]
    ).map { try decode(type, row: $0) }
  }

  private func fetchOne<T: Decodable>(
    _ type: T.Type, table: String, fiscalYearID: EntityID
  ) throws -> T? {
    try connection.query(
      "SELECT payload_json FROM \(table) WHERE fiscal_year_id = ? LIMIT 1",
      bindings: [.text(fiscalYearID.filingDatabaseString)]
    ).first.map { try decode(type, row: $0) }
  }

  private func rowBindings<T: Encodable>(
    _ id: EntityID, _ fiscalYearID: EntityID, _ value: T
  ) throws -> [SQLiteValue] {
    [
      .text(id.filingDatabaseString), .text(fiscalYearID.filingDatabaseString),
      .text(String(decoding: try encoder.encode(value), as: UTF8.self)),
    ]
  }

  private func decode<T: Decodable>(_ type: T.Type, row: SQLiteRow) throws -> T {
    guard let json = row["payload_json"]?.string else {
      throw RepositoryError.invalidData("filing payload")
    }
    return try decoder.decode(type, from: Data(json.utf8))
  }
}

extension UUID {
  fileprivate var filingDatabaseString: String { uuidString.lowercased() }
}
