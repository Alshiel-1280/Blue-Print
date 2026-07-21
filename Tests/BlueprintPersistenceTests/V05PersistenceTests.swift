import BlueprintClosing
import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V05PersistenceTests: XCTestCase {
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
        .appendingPathComponent("BluePrintV05-\(UUID().uuidString)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root, !preservesRoot { try? FileManager.default.removeItem(at: root) }
  }

  func testVersion5MigratesToClosingSchemaWithBackupAndDataPreserved() throws {
    try SampleDatabaseFactory.makeVersion5Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )
    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 6)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'fixed_assets'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v5-to-v6"))
  }

  func testGenerateQAFixtureWhenConfigured() throws {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] != nil else { return }
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    try database.accounts.seedStandardAccounts(createdAt: now)
    let fiscalYear = try XCTUnwrap(database.fiscalYears.fetchAll().first)
    if var existing = try database.closing.assets(fiscalYearID: fiscalYear.id).first(where: {
      $0.code == "FA-2026-001"
    }) {
      existing.assetAccountID = try account("1500", database).id
      existing.depreciationExpenseAccountID = try account("5600", database).id
      existing.accumulatedDepreciationAccountID = try account("1590", database).id
      try database.saveFixedAsset(existing, at: now)
      return
    }
    let asset = try FixedAsset(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      code: "FA-2026-001",
      name: "Mac Studio 撮影編集機",
      category: "工具器具備品",
      acquisitionDate: date(2026, 4, 1),
      serviceDate: date(2026, 4, 1),
      acquisitionCost: Money(yen: 480_000),
      usefulLifeYears: 4,
      method: .straightLine,
      businessUseBasisPoints: 9_000,
      assetAccountID: try account("1500", database).id,
      depreciationExpenseAccountID: try account("5600", database).id,
      accumulatedDepreciationAccountID: try account("1590", database).id
    )
    try database.saveFixedAsset(asset, at: now)
    _ = try database.postDepreciation(
      assetID: asset.id,
      calendarYear: fiscalYear.calendarYear,
      at: date(2026, 12, 31)
    )
    try database.saveInventoryClosing(
      InventoryClosing(
        openingInventory: Money(yen: 30_000),
        purchases: Money(yen: 180_000),
        closingInventory: Money(yen: 45_000)
      ),
      at: now
    )
    let rule = try HouseholdAllocationRule(
      name: "通信費",
      expenseAccountID: try account("5300", database).id,
      ownerDrawingsAccountID: try account("3100", database).id,
      personalBasisPoints: 2_000,
      rationale: "利用時間"
    )
    try database.saveHouseholdRule(rule, at: now)
  }

  func testFixedAssetRoundTripsAndDepreciationPostsOnce() throws {
    let context = try configuredDatabase()
    let asset = try FixedAsset(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: context.fiscalYear.id,
      code: "FA-001",
      name: "撮影用Mac",
      category: "工具器具備品",
      acquisitionDate: date(2026, 1, 1),
      serviceDate: date(2026, 1, 1),
      acquisitionCost: Money(yen: 600_000),
      usefulLifeYears: 5,
      method: .straightLine,
      businessUseBasisPoints: 8_000,
      assetAccountID: try account("1000", context.database).id,
      depreciationExpenseAccountID: try account("5100", context.database).id,
      accumulatedDepreciationAccountID: try account("2000", context.database).id
    )
    try context.database.saveFixedAsset(asset, at: now)
    XCTAssertEqual(try context.database.closing.asset(id: asset.id), asset)
    let first = try context.database.postDepreciation(
      assetID: asset.id,
      calendarYear: 2026,
      at: date(2026, 12, 31)
    )
    let second = try context.database.postDepreciation(
      assetID: asset.id,
      calendarYear: 2026,
      at: date(2026, 12, 31)
    )
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.kind, .closing)
    XCTAssertEqual(first.lines.first?.amount, Money(yen: 96_000))
  }

  func testInventoryAndChecklistPersistResolutionState() throws {
    let context = try configuredDatabase()
    let before = try context.database.closingChecklist(asOf: now)
    XCTAssertFalse(try XCTUnwrap(before.items.first { $0.id == "inventory" }).isResolved)
    let inventory = try InventoryClosing(
      openingInventory: Money(yen: 20_000),
      purchases: Money(yen: 80_000),
      closingInventory: Money(yen: 30_000)
    )
    try context.database.saveInventoryClosing(inventory, at: now)
    XCTAssertEqual(
      try context.database.closing.inventory(fiscalYearID: context.fiscalYear.id),
      inventory
    )
    let after = try context.database.closingChecklist(asOf: now)
    XCTAssertTrue(try XCTUnwrap(after.items.first { $0.id == "inventory" }).isResolved)
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

  private func account(_ code: String, _ database: BlueprintDatabase) throws -> Account {
    try XCTUnwrap(database.accounts.fetchAll(includeInactive: false).first { $0.code == code })
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(
      from: DateComponents(year: year, month: month, day: day)
    )!
  }
}
