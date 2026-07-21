import BlueprintDocuments
import BlueprintDomain
import BlueprintTransfer
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V08PortableDataTests: XCTestCase {
  private var root: URL!
  private var databaseURL: URL { root.appendingPathComponent("Database/blueprint.sqlite") }
  private let now = Date(timeIntervalSince1970: 1_735_689_600)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BluePrintV08-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testPortableExportReconstructsValidationDatabaseAndEvidence() throws {
    let context = try configuredDatabase()
    let service = PortableDataService(connection: context.database.connection, root: root)
    let archive = try service.makeArchive(createdAt: now)
    let encoded = try service.encodeArchive(archive)
    let decoded = try service.decodeArchive(encoded)
    let restoredRoot = root.appendingPathComponent("Restored", isDirectory: true)

    try service.restore(decoded, to: restoredRoot)

    let restored = try BlueprintDatabase(
      databaseURL: restoredRoot.appendingPathComponent("Database/blueprint.sqlite"))
    XCTAssertEqual(try restored.profiles.fetchAll().first?.tradeName, "青空デザイン")
    XCTAssertEqual(
      try restored.journals.search(JournalSearch(fiscalYearID: context.fiscalYear.id)).count, 1)
    XCTAssertEqual(decoded.manifest.evidenceCount, 1)
    XCTAssertEqual(Set(decoded.csvTables.keys), Set(decoded.tables.map(\.name)))
    XCTAssertTrue(decoded.csvTables.keys.contains("invoices"))
    XCTAssertTrue(decoded.csvTables.keys.contains("vendor_bills"))
    XCTAssertTrue(decoded.csvTables.keys.contains("fixed_assets"))
    XCTAssertTrue(decoded.csvTables.keys.contains("filing_workspaces"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: restoredRoot.appendingPathComponent(decoded.evidence[0].relativePath).path))
  }

  func testEncryptedBackupRejectsWrongPassphraseAndRestoresWithCorrectOne() throws {
    let context = try configuredDatabase()
    let service = PortableDataService(connection: context.database.connection, root: root)
    let backup = try service.makeEncryptedBackup(passphrase: "correct horse", createdAt: now)

    XCTAssertThrowsError(try service.openEncryptedBackup(backup, passphrase: "wrong")) { error in
      XCTAssertEqual(error as? PortableDataError, .authenticationFailed)
    }
    let archive = try service.openEncryptedBackup(backup, passphrase: "correct horse")
    let preview = service.previewRestore(archive)
    XCTAssertTrue(preview.isCompatible)
    XCTAssertTrue(preview.warnings.isEmpty)
  }

  func testVersion8MigratesToTransferHistoryWithPreMigrationBackup() throws {
    let backups = root.appendingPathComponent("Backups/Migration", isDirectory: true)
    try SampleDatabaseFactory.makeVersion8Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backups)
    )

    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 9)
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'yayoi_migration_batches'"
      ),
      1
    )
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
  }

  func testYayoiBatchImportsAtomicallyAndPersistsHistory() throws {
    let context = try configuredDatabase()
    let accounts = try context.database.accounts.fetchAll(includeInactive: false)
    let csv = yayoiRow(
      debitAccount: "通信費", debitTax: "課対仕入込10%適格",
      creditAccount: "普通預金", creditTax: "対象外", amount: 3_300)
    let preview = try YayoiCSVImporter.preview(
      data: Data(csv.utf8),
      filename: "yayoi.csv",
      product: .desktopOrOnline,
      availableAccounts: accounts,
      importedAt: now
    )

    let imported = try context.database.importYayoiMigration(
      preview, fiscalYearID: context.fiscalYear.id, at: now)

    XCTAssertEqual(imported.count, 1)
    XCTAssertEqual(imported[0].status, .posted)
    XCTAssertEqual(
      try context.database.connection.scalarInt("SELECT COUNT(*) FROM yayoi_migration_batches"),
      1
    )
    XCTAssertEqual(
      try context.database.connection.scalarInt(
        "SELECT COUNT(*) FROM sub_accounts WHERE name = '通信会社'"),
      1
    )

    var invalid = preview
    invalid.accountMappings[0].targetAccountID = nil
    let before = try context.database.journals.search(
      JournalSearch(fiscalYearID: context.fiscalYear.id)
    ).count
    XCTAssertThrowsError(
      try context.database.importYayoiMigration(
        invalid, fiscalYearID: context.fiscalYear.id, at: now))
    XCTAssertEqual(
      try context.database.journals.search(
        JournalSearch(fiscalYearID: context.fiscalYear.id)
      ).count,
      before
    )
  }

  func testAutomaticBackupRetainsConfiguredGenerationsAndDiagnosticsAreHealthy() throws {
    let context = try configuredDatabase()
    let service = PortableDataService(connection: context.database.connection, root: root)
    let directory = root.appendingPathComponent("Backups/Automatic", isDirectory: true)
    for day in 0..<4 {
      _ = try service.writeAutomaticBackup(
        passphrase: "archive-passphrase",
        directory: directory,
        retainGenerations: 3,
        createdAt: now.addingTimeInterval(Double(day) * 86_400)
      )
    }
    let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".blueprintbackup") }
    XCTAssertEqual(backups.count, 3)

    let report = try service.diagnose(createdAt: now)
    XCTAssertTrue(report.isHealthy)
    XCTAssertEqual(report.evidenceChecked, 1)
  }

  func testDiagnosticsReportsMissingEvidenceWithoutCrashing() throws {
    let context = try configuredDatabase()
    let document = try XCTUnwrap(context.database.evidence.search(EvidenceSearch()).first)
    let original = root.appendingPathComponent(
      "Evidence/Originals/\(document.originalRelativePath)")
    try FileManager.default.removeItem(at: original)
    let service = PortableDataService(connection: context.database.connection, root: root)

    let report = try service.diagnose(createdAt: now)

    XCTAssertFalse(report.isHealthy)
    XCTAssertTrue(report.findings.contains { $0.title.contains("証憑原本") })
  }

  func testPendingRestoreIsAppliedOnNextLaunchWithRollbackCopy() throws {
    let context = try configuredDatabase()
    let service = PortableDataService(connection: context.database.connection, root: root)
    let archive = try service.makeArchive(createdAt: now)
    let pending = root.appendingPathComponent("RestorePending", isDirectory: true)
    try service.restore(archive, to: pending)
    try Data("pending".utf8).write(
      to: root.appendingPathComponent("restore-on-next-launch"), options: .atomic)
    var changed = try XCTUnwrap(context.database.profiles.fetchAll().first)
    changed.tradeName = "復元前に変更"
    try context.database.profiles.save(changed)

    let layout = StorageLayout(root: root)
    try layout.applyPendingRestoreIfNeeded()
    let reopened = try BlueprintDatabase(databaseURL: databaseURL)

    XCTAssertEqual(try reopened.profiles.fetchAll().first?.tradeName, "青空デザイン")
    let rollbackRoot = root.appendingPathComponent("Backups/RestoreRollback")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.path).isEmpty)
  }

  private func configuredDatabase() throws -> (database: BlueprintDatabase, fiscalYear: FiscalYear)
  {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2025,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン"
    )
    try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let cash = try XCTUnwrap(accounts.first { $0.name == "現金" })
    let sales = try XCTUnwrap(accounts.first { $0.name == "売上高" })
    let entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: now,
      description: "売上",
      lines: [
        try JournalLine(accountID: cash.id, side: .debit, amount: Money(yen: 10_000)),
        try JournalLine(accountID: sales.id, side: .credit, amount: Money(yen: 10_000)),
      ]
    )
    try database.saveJournalDraft(entry, at: now)
    try database.postJournal(id: entry.id, fiscalYearID: fiscalYear.id, at: now)

    let source = root.appendingPathComponent("receipt.txt")
    try Data("evidence".utf8).write(to: source)
    _ = try database.importEvidence(
      from: source,
      mimeType: "text/plain",
      origin: .electronicTransaction,
      at: now
    )
    return (database, fiscalYear)
  }

  private func yayoiRow(
    debitAccount: String,
    debitTax: String,
    creditAccount: String,
    creditTax: String,
    amount: Int64
  ) -> String {
    var columns = Array(repeating: "", count: 25)
    columns[0] = "2000"
    columns[3] = "2025/04/01"
    columns[4] = debitAccount
    columns[5] = "通信会社"
    columns[7] = debitTax
    columns[8] = String(amount)
    columns[10] = creditAccount
    columns[13] = creditTax
    columns[14] = String(amount)
    columns[16] = "弥生移行"
    return columns.map { "\"\($0)\"" }.joined(separator: ",")
  }
}
