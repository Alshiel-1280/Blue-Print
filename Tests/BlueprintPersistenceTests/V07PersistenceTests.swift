import BlueprintDomain
import BlueprintETax
import BlueprintFiling
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V07PersistenceTests: XCTestCase {
  private var root: URL!
  private var preservesRoot = false
  private var databaseURL: URL { root.appendingPathComponent("Database/blueprint.sqlite") }
  private var backupDirectory: URL { root.appendingPathComponent("Backups") }
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  override func setUpWithError() throws {
    if let path = ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] {
      root = URL(fileURLWithPath: path, isDirectory: true)
      preservesRoot = true
    } else {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BluePrintV07-\(UUID().uuidString)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root, !preservesRoot { try? FileManager.default.removeItem(at: root) }
  }

  func testGenerateQAFixtureWhenConfigured() throws {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] != nil else { return }
    let context = try configuredDatabase()
    try context.database.filing.saveWorkspace(
      FilingWorkspace(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: context.fiscalYear.id,
        reviewItems: [
          FilingReviewItem(
            title: "国外所得の確認",
            detail: "外国税額控除はe-Tax WEB版で追加入力します。",
            state: .needsDecision)
        ]
      ))
    try context.database.filing.saveUnsupportedCase(
      UnsupportedFilingCase(
        fiscalYearID: context.fiscalYear.id,
        title: "外国税額控除",
        guidance: "e-Tax WEB版で外国税額控除の明細を追加入力してください。"
      ))
    try context.database.saveETaxExport(makeRecord(fiscalYearID: context.fiscalYear.id), at: now)
  }

  func testVersion7MigratesToETaxHistorySchemaWithBackupAndDataPreserved() throws {
    try SampleDatabaseFactory.makeVersion7Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )

    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 8)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'e_tax_exports'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v7-to-v8"))
  }

  func testETaxExportHistoryRoundTripsWithHashVersionsAndChecklist() throws {
    let context = try configuredDatabase()
    let record = makeRecord(fiscalYearID: context.fiscalYear.id)

    try context.database.saveETaxExport(record, at: now)

    XCTAssertEqual(
      try context.database.eTax.exports(fiscalYearID: context.fiscalYear.id), [record])
    XCTAssertEqual(
      try context.database.auditEvents.fetch(
        targetType: "ETaxExportRecord", targetID: record.id.uuidString.lowercased()
      ).count,
      1
    )
  }

  func testETaxExportAndAuditRollBackTogetherOnFailure() throws {
    let context = try configuredDatabase()
    let record = makeRecord(fiscalYearID: context.fiscalYear.id)
    try context.database.connection.execute(
      """
      CREATE TRIGGER reject_etax_audit
      BEFORE INSERT ON audit_events
      WHEN NEW.target_type = 'ETaxExportRecord'
      BEGIN SELECT RAISE(ABORT, 'forced e-Tax audit failure'); END
      """)

    XCTAssertThrowsError(try context.database.saveETaxExport(record, at: now))
    XCTAssertTrue(
      try context.database.eTax.exports(fiscalYearID: context.fiscalYear.id).isEmpty)
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
      tradeName: "青空デザイン",
      postalAddress: "東京都千代田区千代田1-1",
      taxAddress: "東京都千代田区千代田1-1",
      taxOffice: "麹町税務署",
      taxOfficeCode: "01101",
      eTaxUserID: "1234567890123456"
    )
    try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
    return (database, fiscalYear)
  }

  private func makeRecord(fiscalYearID: EntityID) -> ETaxExportRecord {
    ETaxExportRecord(
      fiscalYearID: fiscalYearID,
      exportedAt: now,
      fileName: "blue-print-2025.xtx",
      fileHash: String(repeating: "a", count: 64),
      taxRuleSetID: "tax-2025.1",
      formRuleSetID: "form-2025.1",
      schemaVersion: "25.0.0",
      ledgerFingerprint: "ledger-v1",
      checklist: [
        ETaxChecklistItem(
          id: "foreign-tax",
          title: "外国税額控除",
          detail: "e-Tax WEB版で追加入力",
          state: .additionalInput
        )
      ]
    )
  }
}
