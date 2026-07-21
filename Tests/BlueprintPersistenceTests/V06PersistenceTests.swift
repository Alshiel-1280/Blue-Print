import BlueprintDocuments
import BlueprintDomain
import BlueprintFiling
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V06PersistenceTests: XCTestCase {
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
        .appendingPathComponent("BluePrintV06-\(UUID().uuidString)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root, !preservesRoot { try? FileManager.default.removeItem(at: root) }
  }

  func testVersion6MigratesToFilingSchemaWithBackupAndDataPreserved() throws {
    try SampleDatabaseFactory.makeVersion6Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )
    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 7)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'filing_workspaces'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v6-to-v7"))
  }

  func testGenerateQAFixtureWhenConfigured() throws {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] != nil else { return }
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let fiscalYear = try XCTUnwrap(database.fiscalYears.fetchAll().first)
    let evidenceID = try database.evidence.search(EvidenceSearch()).first?.id
    if !(try database.filing.wages(fiscalYearID: fiscalYear.id)).isEmpty {
      if let evidenceID, var workspace = try database.filing.workspace(fiscalYearID: fiscalYear.id)
      {
        workspace.attach(
          FilingAttachment(
            evidenceDocumentID: evidenceID, title: "源泉徴収票 株式会社ブルースカイ", category: "給与"),
          at: now)
        try database.filing.saveWorkspace(workspace)
      }
      return
    }
    let workspace = FilingWorkspace(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      reviewItems: [
        FilingReviewItem(
          title: "配当の申告方法", detail: "総合課税・申告分離・申告不要を確認",
          state: .needsDecision)
      ]
    )
    var workspaceWithAttachment = workspace
    if let evidenceID {
      workspaceWithAttachment.attach(
        FilingAttachment(
          evidenceDocumentID: evidenceID, title: "源泉徴収票 株式会社ブルースカイ", category: "給与"),
        at: now)
    }
    try database.filing.saveWorkspace(workspaceWithAttachment)
    try database.filing.saveWage(
      WageWithholdingStatement(
        fiscalYearID: fiscalYear.id,
        payerName: "株式会社ブルースカイ",
        paymentAmount: Money(yen: 3_600_000),
        withholdingTax: Money(yen: 142_000),
        socialInsurance: Money(yen: 520_000),
        evidenceDocumentID: evidenceID,
        reviewState: .confirmed
      ))
    try database.filing.saveWage(
      WageWithholdingStatement(
        fiscalYearID: fiscalYear.id,
        payerName: "青空クリエイティブ合同会社",
        paymentAmount: Money(yen: 480_000),
        withholdingTax: Money(yen: 18_000),
        socialInsurance: .zero,
        reviewState: .unconfirmed
      ))
    let property = try FilingProperty(
      fiscalYearID: fiscalYear.id,
      name: "青空ハイツ 201",
      address: "東京都渋谷区",
      tenantName: "入居者A",
      sharedFixedAssetIDs: try database.closing.assets(fiscalYearID: fiscalYear.id).map(\.id)
    )
    try database.filing.saveProperty(property)
    for entry in [
      try RentalLedgerEntry(
        fiscalYearID: fiscalYear.id, propertyID: property.id, transactionDate: now,
        kind: .rentRevenue, description: "年間家賃", amount: Money(yen: 1_440_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYear.id, propertyID: property.id, transactionDate: now,
        kind: .expense, description: "修繕費", amount: Money(yen: 180_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYear.id, propertyID: nil, transactionDate: now,
        kind: .expense, description: "共通管理費", amount: Money(yen: 60_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYear.id, propertyID: property.id, transactionDate: now,
        kind: .depreciation, description: "建物減価償却", amount: Money(yen: 240_000)),
    ] { try database.filing.saveRentalEntry(entry) }
    try database.filing.saveSecuritiesReport(
      SecuritiesAnnualReport(
        fiscalYearID: fiscalYear.id,
        brokerName: "青空証券",
        accountName: "特定口座（源泉あり）",
        withholdingKind: .withholding,
        proceeds: Money(yen: 2_800_000),
        acquisitionCost: Money(yen: 2_450_000),
        nationalWithholdingTax: Money(yen: 53_600),
        localWithholdingTax: Money(yen: 17_500),
        dividendAmount: Money(yen: 82_000),
        dividendWithholdingTax: Money(yen: 16_600),
        reviewState: .needsDecision
      ))
    try database.filing.saveLossCarryforward(
      StockLossCarryforward(
        fiscalYearID: fiscalYear.id,
        sourceYear: 2025,
        broughtForward: Money(yen: 300_000),
        currentYearLoss: .zero,
        utilized: Money(yen: 200_000)
      ))
    try database.filing.saveOtherIncome(
      OtherIncomeEntry(
        fiscalYearID: fiscalYear.id,
        kind: .miscellaneous,
        title: "執筆・講演",
        revenue: Money(yen: 180_000),
        expenses: Money(yen: 20_000),
        withholdingTax: Money(yen: 18_378),
        reviewState: .confirmed
      ))
    try database.filing.saveDeduction(
      FilingDeduction(
        fiscalYearID: fiscalYear.id,
        kind: .donation,
        title: "ふるさと納税",
        amount: Money(yen: 80_000),
        reviewState: .unconfirmed
      ))
    try database.filing.saveUnsupportedCase(
      UnsupportedFilingCase(
        fiscalYearID: fiscalYear.id,
        title: "国外所得の税額控除",
        guidance: "e-Tax WEB版で外国税額控除の明細を追加入力してください。"
      ))
  }

  func testFilingRecordsRoundTripByFiscalYearWithoutCreatingJournals() throws {
    let context = try configuredDatabase()
    let workspace = FilingWorkspace(
      metadata: EntityMetadata(createdAt: now), fiscalYearID: context.fiscalYear.id)
    let wage = try WageWithholdingStatement(
      fiscalYearID: context.fiscalYear.id,
      payerName: "株式会社サンプル",
      paymentAmount: Money(yen: 3_000_000),
      withholdingTax: Money(yen: 120_000),
      socialInsurance: Money(yen: 300_000)
    )
    let securities = try SecuritiesAnnualReport(
      fiscalYearID: context.fiscalYear.id,
      brokerName: "青空証券",
      accountName: "特定口座",
      withholdingKind: .withholding,
      proceeds: Money(yen: 1_000_000),
      acquisitionCost: Money(yen: 800_000)
    )
    try context.database.filing.saveWorkspace(workspace)
    try context.database.filing.saveWage(wage)
    try context.database.filing.saveSecuritiesReport(securities)

    XCTAssertEqual(
      try context.database.filing.workspace(fiscalYearID: context.fiscalYear.id), workspace)
    XCTAssertEqual(try context.database.filing.wages(fiscalYearID: context.fiscalYear.id), [wage])
    XCTAssertEqual(
      try context.database.filing.securitiesReports(fiscalYearID: context.fiscalYear.id),
      [securities]
    )
    XCTAssertTrue(
      try context.database.journals.search(JournalSearch(fiscalYearID: context.fiscalYear.id))
        .isEmpty)
  }

  func testPropertyAndBusinessDataRemainSeparate() throws {
    let context = try configuredDatabase()
    let property = try FilingProperty(
      fiscalYearID: context.fiscalYear.id,
      name: "青空ハイツ",
      address: "東京都",
      tenantName: "入居者A"
    )
    let rent = try RentalLedgerEntry(
      fiscalYearID: context.fiscalYear.id,
      propertyID: property.id,
      transactionDate: now,
      kind: .rentRevenue,
      description: "1月家賃",
      amount: Money(yen: 100_000)
    )
    try context.database.filing.saveProperty(property)
    try context.database.filing.saveRentalEntry(rent)

    XCTAssertEqual(
      try context.database.filing.properties(fiscalYearID: context.fiscalYear.id), [property])
    XCTAssertEqual(
      PropertyIncomeReport.make(
        entries: try context.database.filing.rentalEntries(fiscalYearID: context.fiscalYear.id)
      ).income,
      Money(yen: 100_000)
    )
    XCTAssertTrue(
      try context.database.journals.search(JournalSearch(fiscalYearID: context.fiscalYear.id))
        .isEmpty)
  }

  func testFilingRecordAttachmentAndAuditRollBackTogetherOnFailure() throws {
    let context = try configuredDatabase()
    let workspace = FilingWorkspace(
      metadata: EntityMetadata(createdAt: now), fiscalYearID: context.fiscalYear.id)
    try context.database.filing.saveWorkspace(workspace)
    try context.database.connection.execute(
      """
      CREATE TRIGGER reject_wage_audit
      BEFORE INSERT ON audit_events
      WHEN NEW.target_type = 'WageWithholdingStatement'
      BEGIN SELECT RAISE(ABORT, 'forced filing audit failure'); END
      """)
    let wage = try WageWithholdingStatement(
      fiscalYearID: context.fiscalYear.id,
      payerName: "失敗テスト株式会社",
      paymentAmount: Money(yen: 100_000),
      withholdingTax: Money(yen: 5_000),
      socialInsurance: .zero
    )
    XCTAssertThrowsError(
      try context.database.saveWageStatement(
        wage,
        attachment: FilingAttachment(
          evidenceDocumentID: UUID(), title: "源泉徴収票", category: "給与"),
        at: now
      ))
    XCTAssertTrue(
      try context.database.filing.wages(fiscalYearID: context.fiscalYear.id).isEmpty)
    XCTAssertTrue(
      try XCTUnwrap(context.database.filing.workspace(fiscalYearID: context.fiscalYear.id))
        .attachments.isEmpty)
  }

  private func configuredDatabase() throws -> (database: BlueprintDatabase, fiscalYear: FiscalYear)
  {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "青空 太郎",
      tradeName: "青空デザイン"
    )
    try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
    return (database, fiscalYear)
  }
}
