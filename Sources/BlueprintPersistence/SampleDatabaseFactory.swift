import BlueprintDomain
import Foundation

public enum SampleDatabaseFactory {
  public static func makeVersion1Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion2Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try connection.execute("DROP TABLE capture_sources")
    try connection.execute("DELETE FROM version_metadata WHERE key = 'capture_protocol_version'")
    try connection.execute("PRAGMA user_version = 1")
  }

  public static func makeVersion2Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion3Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try connection.execute("DROP TABLE journal_lines")
    try connection.execute("DROP TABLE journal_entries")
    try connection.execute("PRAGMA user_version = 2")
  }

  public static func makeVersion3Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion4Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try connection.execute("DROP TABLE evidence_links")
    try connection.execute("DROP TABLE ocr_candidates")
    try connection.execute("DROP TABLE import_row_errors")
    try connection.execute("DROP TABLE imported_transactions")
    try connection.execute("DROP TABLE import_batches")
    try connection.execute("DROP TABLE import_profiles")
    try connection.execute("DROP TABLE evidence_documents")
    try connection.execute("ALTER TABLE journal_lines DROP COLUMN rounding_unit")
    try connection.execute("ALTER TABLE journal_lines DROP COLUMN deductible_basis_points")
    try connection.execute("ALTER TABLE journal_lines DROP COLUMN invoice_status")
    try connection.execute(
      "UPDATE version_metadata SET value = '0.2.1' WHERE key = 'app_version'"
    )
    try connection.execute(
      "UPDATE version_metadata SET value = '2' WHERE key = 'data_format_version'"
    )
    try connection.execute("PRAGMA user_version = 3")
  }

  public static func makeVersion4Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion5Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try connection.execute("DROP TABLE invoice_reissues")
    try connection.execute("DROP TABLE invoices")
    try connection.execute("DROP TABLE vendor_bills")
    try connection.execute("DROP TABLE counterparties")
    try connection.execute(
      "UPDATE version_metadata SET value = '0.3.0' WHERE key = 'app_version'"
    )
    try connection.execute(
      "UPDATE version_metadata SET value = '3' WHERE key = 'data_format_version'"
    )
    try connection.execute("PRAGMA user_version = 4")
  }

  public static func makeVersion5Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion6Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try connection.execute("DROP TABLE closing_inventories")
    try connection.execute("DROP TABLE accrual_templates")
    try connection.execute("DROP TABLE household_allocation_rules")
    try connection.execute("DROP TABLE fixed_assets")
    try connection.execute(
      "UPDATE version_metadata SET value = '0.4.0' WHERE key = 'app_version'"
    )
    try connection.execute(
      "UPDATE version_metadata SET value = '4' WHERE key = 'data_format_version'"
    )
    try connection.execute("PRAGMA user_version = 5")
  }

  public static func makeVersion6Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try makeVersion7Database(at: databaseURL, profileName: profileName, date: date)
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    let filingTables = [
      "unsupported_filing_cases", "filing_deductions", "other_income_entries",
      "stock_loss_carryforwards", "securities_annual_reports", "rental_ledger_entries",
      "filing_properties", "wage_statements", "filing_workspaces",
    ]
    for table in filingTables { try connection.execute("DROP TABLE \(table)") }
    try connection.execute(
      "UPDATE version_metadata SET value = '0.5.0' WHERE key = 'app_version'"
    )
    try connection.execute(
      "UPDATE version_metadata SET value = '5' WHERE key = 'data_format_version'"
    )
    try connection.execute("PRAGMA user_version = 6")
  }

  public static func makeVersion7Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try DatabaseMigrator().migrate(
      connection: connection,
      backupHook: NoopMigrationBackupHook()
    )
    try connection.execute("DROP TABLE e_tax_exports")
    try connection.execute(
      "UPDATE version_metadata SET value = '0.6.0' WHERE key = 'app_version'"
    )
    try connection.execute(
      "UPDATE version_metadata SET value = '6' WHERE key = 'data_format_version'"
    )
    try connection.execute("PRAGMA user_version = 7")

    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: date),
      calendarYear: 2026,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYear.id,
      ownerName: "テスト利用者",
      tradeName: profileName
    )
    let fiscalRepository = SQLiteFiscalYearRepository(connection: connection)
    let profileRepository = SQLiteBusinessProfileRepository(connection: connection)
    try fiscalRepository.save(fiscalYear)
    try profileRepository.save(profile)
  }
}
