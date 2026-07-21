import BlueprintDomain
import Foundation

public enum SampleDatabaseFactory {
  public static func makeVersion1Database(
    at databaseURL: URL,
    profileName: String = "移行テスト事業者",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try DatabaseMigrator().migrate(
      connection: connection,
      backupHook: NoopMigrationBackupHook()
    )
    try connection.execute("DROP TABLE capture_sources")
    try connection.execute("DELETE FROM version_metadata WHERE key = 'capture_protocol_version'")
    try connection.execute("PRAGMA user_version = 1")

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
