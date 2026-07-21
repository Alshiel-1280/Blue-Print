import BlueprintAudit
import BlueprintDomain
import XCTest

@testable import BlueprintPersistence

final class PersistenceTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var databaseURL: URL {
    temporaryDirectory.appendingPathComponent("Database/blueprint.sqlite")
  }
  private var backupDirectory: URL { temporaryDirectory.appendingPathComponent("Backups") }
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BluePrintTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testFreshDatabaseMigratesToLatestSchemaAndStoresIndependentVersions() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 2)

    let rows = try database.connection.query("SELECT key, value FROM version_metadata")
    let versions = Dictionary(
      uniqueKeysWithValues: try rows.map { row in
        guard case .text(let key)? = row["key"], case .text(let value)? = row["value"] else {
          throw RepositoryError.invalidData("version row")
        }
        return (key, value)
      })
    XCTAssertEqual(versions["app_version"], BlueprintVersions.app)
    XCTAssertEqual(versions["data_format_version"], String(BlueprintVersions.dataFormat))
    XCTAssertEqual(versions["tax_rule_set_version"], BlueprintVersions.taxRuleSet)
    XCTAssertEqual(versions["form_rule_set_version"], BlueprintVersions.formRuleSet)
    XCTAssertEqual(versions["capture_protocol_version"], String(BlueprintVersions.captureProtocol))
  }

  func testInitialSetupRoundTripsAfterDatabaseReopen() throws {
    let first = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try first.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)

    XCTAssertEqual(try first.profiles.fetchAll(), [setup.profile])
    XCTAssertEqual(try first.fiscalYears.fetchAll(), [setup.fiscalYear])
    XCTAssertEqual(try first.accounts.fetchAll(includeInactive: true).count, 15)

    let reopened = try BlueprintDatabase(databaseURL: databaseURL)
    XCTAssertEqual(try reopened.profiles.fetchAll(), [setup.profile])
    XCTAssertEqual(try reopened.fiscalYears.fetchAll(), [setup.fiscalYear])
    XCTAssertTrue(try reopened.isSetupComplete())
  }

  func testStandardAccountsSeedIdempotentlyWithoutDuplicates() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    try database.accounts.seedStandardAccounts(createdAt: now)
    try database.accounts.seedStandardAccounts(createdAt: now.addingTimeInterval(1))
    let accounts = try database.accounts.fetchAll(includeInactive: true)
    XCTAssertEqual(accounts.count, 15)
    XCTAssertEqual(Set(accounts.map(\.code)).count, 15)
  }

  func testAccountCannotBePhysicallyDeletedAndDeactivationIsAudited() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let account = try XCTUnwrap(database.accounts.fetchAll(includeInactive: true).first)

    XCTAssertThrowsError(try database.accounts.delete(id: account.id)) { error in
      XCTAssertEqual(error as? RepositoryError, .physicalDeletionForbidden)
    }

    try database.deactivateAccount(id: account.id, at: now.addingTimeInterval(20))
    let updated = try XCTUnwrap(
      database.accounts.fetchAll(includeInactive: true).first { $0.id == account.id })
    XCTAssertFalse(updated.isActive)
    XCTAssertEqual(
      try database.auditEvents.fetch(
        targetType: "Account", targetID: account.id.uuidString.lowercased()
      ).last?.action,
      .deactivated
    )
  }

  func testAuditEventsRejectUpdateAndDeleteAtDatabaseBoundary() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let event = AuditEvent(
      occurredAt: now,
      actorKind: .localUser,
      action: .created,
      targetType: "BusinessProfile",
      targetID: "target"
    )
    try database.auditEvents.append(event)

    XCTAssertThrowsError(
      try database.connection.execute(
        "UPDATE audit_events SET action = 'updated' WHERE id = ?",
        bindings: [.text(event.id.uuidString.lowercased())]
      )
    )
    XCTAssertThrowsError(
      try database.connection.execute(
        "DELETE FROM audit_events WHERE id = ?",
        bindings: [.text(event.id.uuidString.lowercased())]
      )
    )
    XCTAssertEqual(try database.auditEvents.fetchAll(), [event])
  }

  func testTransactionRollsBackAllWritesOnError() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    enum Expected: Error { case stop }

    XCTAssertThrowsError(
      try database.connection.transaction {
        try database.connection.execute(
          "INSERT INTO version_metadata(key, value) VALUES ('temporary', 'value')"
        )
        throw Expected.stop
      }
    )
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM version_metadata WHERE key = 'temporary'"),
      0
    )
  }

  func testVersion1SampleMigratesWithoutDataLossAndCreatesPreMigrationBackup() throws {
    try SampleDatabaseFactory.makeVersion1Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )

    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 2)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'capture_sources'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v1-to-v2"))
  }

  func testInitialSetupFailureDoesNotPartiallyPersist() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.connection.execute(
      """
      CREATE TRIGGER reject_profile_insert
      BEFORE INSERT ON business_profiles
      BEGIN SELECT RAISE(ABORT, 'forced setup failure'); END
      """
    )

    XCTAssertThrowsError(
      try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    )
    XCTAssertTrue(try database.profiles.fetchAll().isEmpty)
    XCTAssertTrue(try database.fiscalYears.fetchAll().isEmpty)
    XCTAssertTrue(try database.accounts.fetchAll(includeInactive: true).isEmpty)
    XCTAssertTrue(try database.auditEvents.fetchAll().isEmpty)
  }

  private func makeSetup() throws -> (profile: BusinessProfile, fiscalYear: FiscalYear) {
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(
        id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        createdAt: now
      ),
      calendarYear: 2026,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        createdAt: now
      ),
      fiscalYearID: fiscalYear.id,
      ownerName: "青空 太郎",
      tradeName: "青空デザイン"
    )
    return (profile, fiscalYear)
  }
}
