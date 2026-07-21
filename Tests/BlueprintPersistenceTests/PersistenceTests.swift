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
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

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
    XCTAssertEqual(
      try database.connection.scalarInt("PRAGMA user_version"),
      Int64(BlueprintVersions.databaseSchema)
    )

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
    XCTAssertEqual(try first.accounts.fetchAll(includeInactive: true).count, 25)

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
    XCTAssertEqual(accounts.count, 25)
    XCTAssertEqual(Set(accounts.map(\.code)).count, 25)
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

    XCTAssertEqual(
      try database.connection.scalarInt("PRAGMA user_version"),
      Int64(BlueprintVersions.databaseSchema)
    )
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
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v1-to-v6"))
  }

  func testVersion2DatabaseMigratesToJournalSchemaWithoutDataLoss() throws {
    try SampleDatabaseFactory.makeVersion2Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )

    XCTAssertEqual(
      try database.connection.scalarInt("PRAGMA user_version"),
      Int64(BlueprintVersions.databaseSchema)
    )
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'journal_entries'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v2-to-v6"))
  }

  func testJournalPostingRoundTripSearchAndPhysicalDeletionBoundary() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let entry = try makeJournal(
      fiscalYearID: setup.fiscalYear.id,
      debitAccountID: accounts[0].id,
      creditAccountID: accounts[8].id
    )

    try database.saveJournalDraft(entry, at: now)
    XCTAssertEqual(try database.journals.fetch(id: entry.id)?.status, .draft)
    try database.postJournal(
      id: entry.id,
      fiscalYearID: setup.fiscalYear.id,
      at: now.addingTimeInterval(1)
    )

    let posted = try XCTUnwrap(database.journals.fetch(id: entry.id))
    XCTAssertEqual(posted.status, .posted)
    XCTAssertEqual(try posted.totals().debits, Money(yen: 12_480))
    XCTAssertEqual(
      try database.journals.search(
        JournalSearch(fiscalYearID: setup.fiscalYear.id, text: "成城石井")
      ).map(\.id),
      [entry.id]
    )
    XCTAssertThrowsError(try database.journals.delete(id: entry.id)) { error in
      XCTAssertEqual(error as? RepositoryError, .physicalDeletionForbidden)
    }
  }

  func testUnbalancedJournalCannotPostAndDoesNotPartiallyAudit() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let lines = [
      try JournalLine(accountID: accounts[0].id, side: .debit, amount: Money(yen: 1_000)),
      try JournalLine(accountID: accounts[8].id, side: .credit, amount: Money(yen: 900)),
    ]
    let entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: setup.fiscalYear.id,
      transactionDate: now,
      description: "不一致",
      lines: lines
    )
    try database.saveJournalDraft(entry, at: now)
    let auditCount = try database.auditEvents.fetchAll().count

    XCTAssertThrowsError(
      try database.postJournal(id: entry.id, fiscalYearID: setup.fiscalYear.id, at: now)
    )
    XCTAssertEqual(try database.journals.fetch(id: entry.id)?.status, .draft)
    XCTAssertEqual(try database.auditEvents.fetchAll().count, auditCount)
  }

  func testReversalRestoresTrialBalanceAndLinksOriginal() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let entry = try makeJournal(
      fiscalYearID: setup.fiscalYear.id,
      debitAccountID: accounts[0].id,
      creditAccountID: accounts[8].id
    )
    try database.saveJournalDraft(entry, at: now)
    try database.postJournal(id: entry.id, fiscalYearID: setup.fiscalYear.id, at: now)
    let reversal = try database.reverseJournal(
      id: entry.id,
      reason: "二重入力",
      at: now.addingTimeInterval(2)
    )

    XCTAssertEqual(reversal.sourceEntryID, entry.id)
    XCTAssertEqual(reversal.status, .posted)
    XCTAssertEqual(try database.journals.fetch(id: entry.id)?.status, .reversed)
    let entries = try database.journals.search(
      JournalSearch(fiscalYearID: setup.fiscalYear.id)
    )
    let trial = try AccountingReports.trialBalance(entries: entries)
    XCTAssertEqual(trial.totalDebits, Money(yen: 24_960))
    XCTAssertEqual(trial.totalCredits, Money(yen: 24_960))
    XCTAssertTrue(trial.accounts.allSatisfy { $0.net == .zero })
  }

  func testLockedFiscalYearRejectsPosting() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let entry = try makeJournal(
      fiscalYearID: setup.fiscalYear.id,
      debitAccountID: accounts[0].id,
      creditAccountID: accounts[8].id
    )
    try database.saveJournalDraft(entry, at: now)
    try database.lockFiscalYear(id: setup.fiscalYear.id, at: now)

    XCTAssertThrowsError(
      try database.postJournal(id: entry.id, fiscalYearID: setup.fiscalYear.id, at: now)
    ) { error in
      XCTAssertEqual(error as? RepositoryError, .fiscalYearLocked)
    }
    var changedProfile = setup.profile
    changedProfile.tradeName = "変更不可"
    XCTAssertThrowsError(try database.saveProfile(changedProfile, at: now)) { error in
      XCTAssertEqual(error as? RepositoryError, .fiscalYearLocked)
    }
    XCTAssertThrowsError(try database.deactivateAccount(id: accounts[0].id, at: now)) { error in
      XCTAssertEqual(error as? RepositoryError, .fiscalYearLocked)
    }
  }

  func testCorrectionCreatesLinkedReversalAndReplacementAtomically() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let original = try makeJournal(
      fiscalYearID: setup.fiscalYear.id,
      debitAccountID: accounts[0].id,
      creditAccountID: accounts[8].id
    )
    try database.saveJournalDraft(original, at: now)
    try database.postJournal(id: original.id, fiscalYearID: setup.fiscalYear.id, at: now)
    let correctedLines = [
      try JournalLine(accountID: accounts[1].id, side: .debit, amount: Money(yen: 8_000)),
      try JournalLine(accountID: accounts[8].id, side: .credit, amount: Money(yen: 8_000)),
    ]

    let result = try database.correctJournal(
      id: original.id,
      transactionDate: now,
      description: "訂正後",
      lines: correctedLines,
      reason: "金額と口座を訂正",
      at: now.addingTimeInterval(3)
    )

    XCTAssertEqual(try database.journals.fetch(id: original.id)?.status, .corrected)
    XCTAssertEqual(result.reversal.sourceEntryID, original.id)
    XCTAssertEqual(result.correction.sourceEntryID, original.id)
    XCTAssertEqual(result.correction.kind, .correction)
    XCTAssertEqual(result.correction.status, .posted)
    XCTAssertEqual(
      try database.auditEvents.fetch(
        targetType: "JournalEntry",
        targetID: original.id.uuidString.lowercased()
      ).last?.action,
      .corrected
    )
  }

  func testTenThousandJournalSearchAndAggregationPerformance() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let setup = try makeSetup()
    try database.createInitialSetup(profile: setup.profile, fiscalYear: setup.fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let fiscalID = setup.fiscalYear.id.uuidString.lowercased()
    let debitID = accounts[0].id.uuidString.lowercased()
    let creditID = accounts[8].id.uuidString.lowercased()

    try database.connection.transaction {
      try database.connection.execute(
        """
        WITH RECURSIVE seq(x) AS (
          SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 10000
        )
        INSERT INTO journal_entries (
          id, fiscal_year_id, transaction_date, description, kind, status,
          source_entry_id, reason, posted_at, created_at, updated_at
        )
        SELECT lower(printf('%08x-0000-4000-8000-%012x', x, x)), ?, ?,
               '一括性能測定', 'standard', 'posted', NULL, NULL, ?, ?, ?
        FROM seq
        """,
        bindings: [
          .text(fiscalID), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
        ]
      )
      try database.connection.execute(
        """
        WITH RECURSIVE seq(x) AS (
          SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 10000
        )
        INSERT INTO journal_lines (
          id, entry_id, account_id, sub_account_id, side, amount_yen,
          tax_rate, counterparty, memo, line_order
        )
        SELECT lower(printf('%08x-0000-4100-8000-%012x', x, x)),
               lower(printf('%08x-0000-4000-8000-%012x', x, x)),
               ?, NULL, 'debit', 100 + x, 'outOfScope', '性能測定先', '', 0
        FROM seq
        """,
        bindings: [.text(debitID)]
      )
      try database.connection.execute(
        """
        WITH RECURSIVE seq(x) AS (
          SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 10000
        )
        INSERT INTO journal_lines (
          id, entry_id, account_id, sub_account_id, side, amount_yen,
          tax_rate, counterparty, memo, line_order
        )
        SELECT lower(printf('%08x-0000-4200-8000-%012x', x, x)),
               lower(printf('%08x-0000-4000-8000-%012x', x, x)),
               ?, NULL, 'credit', 100 + x, 'outOfScope', '', '', 1
        FROM seq
        """,
        bindings: [.text(creditID)]
      )
    }

    let started = Date()
    let entries = try database.journals.search(
      JournalSearch(fiscalYearID: setup.fiscalYear.id, text: "一括")
    )
    let trial = try AccountingReports.trialBalance(entries: entries)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(entries.count, 10_000)
    XCTAssertTrue(trial.isBalanced)
    XCTAssertLessThan(elapsed, 30, "10,000仕訳の検索・集計に \(elapsed) 秒かかりました")
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

  private func makeJournal(
    fiscalYearID: EntityID,
    debitAccountID: EntityID,
    creditAccountID: EntityID
  ) throws -> JournalEntry {
    JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      transactionDate: now,
      description: "成城石井 食材",
      lines: [
        try JournalLine(
          accountID: debitAccountID,
          side: .debit,
          amount: Money(yen: 12_480),
          taxRate: .standard10,
          counterparty: "成城石井"
        ),
        try JournalLine(
          accountID: creditAccountID,
          side: .credit,
          amount: Money(yen: 12_480)
        ),
      ]
    )
  }
}
