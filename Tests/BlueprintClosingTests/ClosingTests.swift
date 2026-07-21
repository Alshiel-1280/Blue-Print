import BlueprintBilling
import BlueprintDomain
import Foundation
import PDFKit
import XCTest

@testable import BlueprintClosing

final class ClosingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)
  private let fiscalYearID = UUID()

  func testStraightLineGoldenScheduleAndBusinessUse() throws {
    var asset = try makeAsset(
      cost: 1_200_000,
      usefulLife: 5,
      method: .straightLine,
      serviceDate: date(2026, 7, 1)
    )
    try asset.changeBusinessUse(to: 8_000, on: date(2028, 1, 1), note: "在宅利用見直し")
    let schedule = try asset.depreciationSchedule(through: 2031)

    XCTAssertEqual(
      schedule.map(\.accountingDepreciation.yen),
      [120_000, 240_000, 240_000, 240_000, 240_000, 119_999])
    XCTAssertEqual(
      schedule.map(\.businessUseBasisPoints), [10_000, 10_000, 8_000, 8_000, 8_000, 8_000])
    XCTAssertEqual(schedule.last?.closingBookValue, Money(yen: 1))
  }

  func testDecliningImmediateAndPooledMethodsHaveGoldenAmounts() throws {
    let declining = try makeAsset(
      cost: 1_000_000,
      usefulLife: 5,
      method: .decliningBalance,
      serviceDate: date(2026, 1, 1),
      decliningRate: 2_000
    )
    XCTAssertEqual(
      try declining.depreciationSchedule(through: 2028).map(\.accountingDepreciation.yen),
      [200_000, 160_000, 128_000]
    )
    let immediate = try makeAsset(
      cost: 98_000,
      usefulLife: 1,
      method: .immediateExpense,
      serviceDate: date(2026, 10, 1)
    )
    XCTAssertEqual(
      try immediate.depreciationSchedule(through: 2026).first?.accountingDepreciation,
      Money(yen: 98_000)
    )
    let pooled = try makeAsset(
      cost: 270_000,
      usefulLife: 3,
      method: .pooledThreeYear,
      serviceDate: date(2026, 1, 1)
    )
    XCTAssertEqual(
      try pooled.depreciationSchedule(through: 2028).map(\.accountingDepreciation.yen),
      [90_000, 90_000, 90_000]
    )
  }

  func testHouseholdAllocationAndInventoryClosingEntriesBalance() throws {
    let fiscalYear = try makeFiscalYear()
    let rule = try HouseholdAllocationRule(
      name: "通信費",
      expenseAccountID: UUID(),
      ownerDrawingsAccountID: UUID(),
      personalBasisPoints: 3_000,
      rationale: "利用時間"
    )
    let allocation = try XCTUnwrap(
      rule.adjustmentEntry(
        fiscalYear: fiscalYear,
        expenseBalance: Money(yen: 100_000),
        transactionDate: date(2026, 12, 31),
        at: now
      )
    )
    XCTAssertEqual(allocation.kind, .closing)
    XCTAssertEqual(allocation.lines.map(\.amount.yen), [30_000, 30_000])

    let inventory = try InventoryClosing(
      openingInventory: Money(yen: 20_000),
      purchases: Money(yen: 100_000),
      closingInventory: Money(yen: 30_000)
    )
    XCTAssertEqual(inventory.costOfGoodsSold, Money(yen: 90_000))
    let entry = try XCTUnwrap(
      inventory.closingEntry(
        fiscalYear: fiscalYear,
        inventoryAccountID: UUID(),
        purchasesAccountID: UUID(),
        transactionDate: date(2026, 12, 31),
        at: now
      )
    )
    XCTAssertEqual(entry.kind, .closing)
    XCTAssertEqual(try entry.totals().debits, Money(yen: 10_000))
    XCTAssertEqual(try entry.totals().credits, Money(yen: 10_000))
  }

  func testAllAccrualTemplateKindsGenerateClosingEntries() throws {
    let fiscalYear = try makeFiscalYear()
    let templates = try AccrualTemplate.standard(
      accounts: StandardChartOfAccounts.accounts(createdAt: now))
    XCTAssertEqual(templates.map(\.kind), AccrualTemplateKind.allCases)
    for template in templates {
      let entry = try template.entry(
        fiscalYear: fiscalYear,
        amount: Money(yen: 12_345),
        transactionDate: date(2026, 12, 31),
        at: now
      )
      XCTAssertEqual(entry.kind, .closing)
      XCTAssertEqual(try entry.totals().debits, Money(yen: 12_345))
      XCTAssertEqual(try entry.totals().credits, Money(yen: 12_345))
    }
  }

  func testAcquisitionSaleAndRetirementGenerateTraceableBalancedJournals() throws {
    let fiscalYear = try makeFiscalYear()
    var asset = try makeAsset(
      cost: 600_000,
      usefulLife: 5,
      method: .straightLine,
      serviceDate: date(2026, 1, 1)
    )
    let acquisition = try asset.acquisitionJournal(
      fiscalYear: fiscalYear,
      paymentAccountID: UUID(),
      at: now
    )
    XCTAssertEqual(try acquisition.totals().debits, Money(yen: 600_000))
    XCTAssertEqual(asset.events.map(\.kind), [.acquired, .placedInService])

    try asset.dispose(on: date(2026, 12, 31), proceeds: Money(yen: 520_000), note: "機材更新")
    let disposal = try asset.disposalJournal(
      fiscalYear: fiscalYear,
      cashAccountID: UUID(),
      gainAccountID: UUID(),
      lossAccountID: UUID(),
      at: now
    )
    XCTAssertEqual(disposal.kind, .closing)
    XCTAssertEqual(try disposal.totals().debits, try disposal.totals().credits)
    XCTAssertEqual(
      disposal.lines.filter { $0.side == .credit }.map(\.amount.yen).sorted(), [40_000, 600_000])
  }

  func testProfitAndLossMatchesBalanceSheetChange() throws {
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let receivable = try account("1200", accounts)
    let bank = try account("1100", accounts)
    let revenue = try account("4000", accounts)
    let expense = try account("5100", accounts)
    let fiscalYear = try makeFiscalYear()
    var sale = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: date(2026, 7, 1),
      description: "売上",
      lines: [
        try JournalLine(accountID: receivable.id, side: .debit, amount: Money(yen: 110_000)),
        try JournalLine(accountID: revenue.id, side: .credit, amount: Money(yen: 110_000)),
      ]
    )
    try sale.post(for: fiscalYear, at: now)
    var cost = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: date(2026, 7, 2),
      description: "外注費",
      lines: [
        try JournalLine(accountID: expense.id, side: .debit, amount: Money(yen: 30_000)),
        try JournalLine(accountID: bank.id, side: .credit, amount: Money(yen: 30_000)),
      ]
    )
    try cost.post(for: fiscalYear, at: now)
    let period = date(2026, 1, 1)...date(2026, 12, 31)
    let profit = try ClosingReports.profitAndLoss(
      entries: [sale, cost],
      accounts: accounts,
      period: period
    )
    let balance = try ClosingReports.balanceSheet(
      entries: [sale, cost],
      accounts: accounts,
      fiscalYearPeriod: period,
      asOf: date(2026, 12, 31)
    )
    XCTAssertEqual(profit.profit, Money(yen: 80_000))
    XCTAssertEqual(balance.currentProfit, profit.profit)
    XCTAssertEqual(balance.totalAssets, Money(yen: 80_000))
    XCTAssertTrue(balance.balances)
  }

  func testUnresolvedClosingChecklistWarnsBeforeFinalization() {
    let checklist = ClosingChecklist(items: [
      ClosingCheckItem(
        id: "evidence",
        title: "未確認証憑",
        detail: "2件あります",
        severity: .blocking,
        isResolved: false
      ),
      ClosingCheckItem(
        id: "inventory",
        title: "棚卸",
        detail: "確認済み",
        severity: .blocking,
        isResolved: true
      ),
    ])
    XCTAssertFalse(checklist.canFinalize)
    XCTAssertEqual(checklist.unresolvedItems.count, 1)
    XCTAssertNotNil(checklist.finalizeWarning)
  }

  func testCSVAndPDFExportsCarryVersionStamp() throws {
    let fiscalYear = try makeFiscalYear()
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let period = date(2026, 1, 1)...date(2026, 12, 31)
    let profit = try ClosingReports.profitAndLoss(entries: [], accounts: accounts, period: period)
    let balance = try ClosingReports.balanceSheet(
      entries: [],
      accounts: accounts,
      fiscalYearPeriod: period,
      asOf: date(2026, 12, 31)
    )
    let csv = ClosingReportExporter.financialStatementsCSV(
      profitAndLoss: profit,
      balanceSheet: balance,
      fiscalYear: fiscalYear
    )
    let csvText = String(decoding: csv, as: UTF8.self)
    XCTAssertTrue(csvText.contains("app=\(BlueprintVersions.app)"))
    XCTAssertTrue(csvText.contains(BlueprintVersions.taxRuleSet))

    let pdf = try ClosingReportExporter.financialStatementsPDF(
      profitAndLoss: profit,
      balanceSheet: balance,
      profileName: "青空デザイン",
      fiscalYear: fiscalYear
    )
    let document = try XCTUnwrap(PDFDocument(data: pdf))
    XCTAssertEqual(document.pageCount, 2)
    let subject =
      document.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
    XCTAssertTrue(subject.contains("app=\(BlueprintVersions.app)"))
    XCTAssertTrue(subject.contains(BlueprintVersions.formRuleSet))
  }

  func testGenerateVerificationExportsWhenOutputRootIsConfigured() throws {
    guard let path = ProcessInfo.processInfo.environment["BLUEPRINT_CLOSING_OUTPUT_ROOT"] else {
      return
    }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let pdfDirectory = root.appendingPathComponent("pdf", isDirectory: true)
    let csvDirectory = root.appendingPathComponent("csv", isDirectory: true)
    try FileManager.default.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: csvDirectory, withIntermediateDirectories: true)
    let fiscalYear = try makeFiscalYear()
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let receivable = try account("1200", accounts)
    let revenue = try account("4000", accounts)
    let expense = try account("5100", accounts)
    let payable = try account("2100", accounts)
    var sale = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: date(2026, 7, 10),
      description: "Webサイト制作売上",
      lines: [
        try JournalLine(accountID: receivable.id, side: .debit, amount: Money(yen: 550_000)),
        try JournalLine(accountID: revenue.id, side: .credit, amount: Money(yen: 550_000)),
      ]
    )
    try sale.post(for: fiscalYear, at: now)
    var cost = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: date(2026, 7, 12),
      description: "UIデザイン外注費",
      lines: [
        try JournalLine(accountID: expense.id, side: .debit, amount: Money(yen: 198_000)),
        try JournalLine(accountID: payable.id, side: .credit, amount: Money(yen: 198_000)),
      ]
    )
    try cost.post(for: fiscalYear, at: now)
    let entries = [sale, cost]
    let period = date(2026, 1, 1)...date(2026, 12, 31)
    let profit = try ClosingReports.profitAndLoss(
      entries: entries,
      accounts: accounts,
      period: period
    )
    let balance = try ClosingReports.balanceSheet(
      entries: entries,
      accounts: accounts,
      fiscalYearPeriod: period,
      asOf: period.upperBound
    )
    try ClosingReportExporter.financialStatementsPDF(
      profitAndLoss: profit,
      balanceSheet: balance,
      profileName: "青空デザイン",
      fiscalYear: fiscalYear
    ).write(to: pdfDirectory.appendingPathComponent("v0.5-financial-statements.pdf"))
    try ClosingReportExporter.journalPDF(
      entries: entries,
      accounts: accounts,
      profileName: "青空デザイン",
      fiscalYear: fiscalYear
    ).write(to: pdfDirectory.appendingPathComponent("v0.5-journal.pdf"))
    try ClosingReportExporter.financialStatementsCSV(
      profitAndLoss: profit,
      balanceSheet: balance,
      fiscalYear: fiscalYear
    ).write(to: csvDirectory.appendingPathComponent("v0.5-financial-statements.csv"))
    try ClosingReportExporter.journalCSV(
      entries: entries,
      accounts: accounts,
      fiscalYear: fiscalYear
    ).write(to: csvDirectory.appendingPathComponent("v0.5-journal.csv"))
  }

  private func makeAsset(
    cost: Int64,
    usefulLife: Int,
    method: DepreciationMethod,
    serviceDate: Date,
    decliningRate: Int = 0
  ) throws -> FixedAsset {
    try FixedAsset(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      code: "A-001",
      name: "制作機材",
      category: "工具器具備品",
      acquisitionDate: serviceDate,
      serviceDate: serviceDate,
      acquisitionCost: Money(yen: cost),
      usefulLifeYears: usefulLife,
      method: method,
      decliningRateBasisPoints: decliningRate,
      assetAccountID: UUID(),
      depreciationExpenseAccountID: UUID(),
      accumulatedDepreciationAccountID: UUID()
    )
  }

  private func makeFiscalYear() throws -> FiscalYear {
    try FiscalYear(
      metadata: EntityMetadata(id: fiscalYearID, createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
  }

  private func account(_ code: String, _ accounts: [Account]) throws -> Account {
    try XCTUnwrap(accounts.first { $0.code == code })
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(
      from: DateComponents(year: year, month: month, day: day)
    )!
  }
}
