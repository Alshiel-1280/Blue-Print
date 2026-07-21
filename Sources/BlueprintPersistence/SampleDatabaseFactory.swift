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
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try DatabaseMigrator().migrate(
      connection: connection,
      backupHook: NoopMigrationBackupHook()
    )
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
