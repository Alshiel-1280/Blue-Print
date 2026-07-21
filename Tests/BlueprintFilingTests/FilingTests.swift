import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintFiling

final class FilingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)
  private let fiscalYearID = UUID()

  func testMultipleWagesAndSecuritiesAggregateWithoutBusinessJournalMixing() throws {
    let workspace = FilingWorkspace(
      metadata: EntityMetadata(createdAt: now), fiscalYearID: fiscalYearID)
    let wages = [
      try wage("株式会社A", payment: 2_000_000, tax: 80_000),
      try wage("株式会社B", payment: 500_000, tax: 20_000),
    ]
    let securities = [
      try SecuritiesAnnualReport(
        fiscalYearID: fiscalYearID,
        brokerName: "青空証券",
        accountName: "特定口座",
        withholdingKind: .withholding,
        proceeds: Money(yen: 900_000),
        acquisitionCost: Money(yen: 700_000),
        nationalWithholdingTax: Money(yen: 30_000),
        localWithholdingTax: Money(yen: 10_000),
        dividendAmount: Money(yen: 50_000),
        dividendWithholdingTax: Money(yen: 10_000)
      ),
      try SecuritiesAnnualReport(
        fiscalYearID: fiscalYearID,
        brokerName: "青空証券",
        accountName: "特定口座2",
        withholdingKind: .noWithholding,
        proceeds: Money(yen: 500_000),
        acquisitionCost: Money(yen: 600_000)
      ),
    ]
    let summary = try FilingAggregation.summary(
      fiscalYearID: fiscalYearID,
      businessIncome: BusinessIncomeSnapshot(
        revenue: Money(yen: 1_000_000), expenses: Money(yen: 400_000),
        income: Money(yen: 600_000), generatedAt: now),
      workspace: workspace,
      wages: wages,
      rentalEntries: [],
      securitiesReports: securities,
      otherIncome: [],
      deductions: [],
      unsupportedCases: []
    )
    XCTAssertEqual(summary.wageRevenue, Money(yen: 2_500_000))
    XCTAssertEqual(summary.securitiesIncome, Money(yen: 150_000))
    XCTAssertEqual(summary.withholdingTax, Money(yen: 150_000))
    XCTAssertEqual(summary.combinedIncomeAndRevenue, Money(yen: 3_250_000))
  }

  func testPropertyLedgersCloseSeparatelyAndDistinguishCommonExpense() throws {
    let propertyID = UUID()
    let entries = [
      try RentalLedgerEntry(
        fiscalYearID: fiscalYearID, propertyID: propertyID, transactionDate: now,
        kind: .rentRevenue, description: "家賃", amount: Money(yen: 1_200_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYearID, propertyID: propertyID, transactionDate: now,
        kind: .expense, description: "修繕", amount: Money(yen: 200_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYearID, propertyID: nil, transactionDate: now,
        kind: .expense, description: "共通管理費", amount: Money(yen: 50_000)),
      try RentalLedgerEntry(
        fiscalYearID: fiscalYearID, propertyID: propertyID, transactionDate: now,
        kind: .depreciation, description: "建物償却", amount: Money(yen: 150_000)),
    ]
    let report = PropertyIncomeReport.make(entries: entries)
    XCTAssertTrue(entries[2].isCommonExpense)
    XCTAssertEqual(report.income, Money(yen: 800_000))
  }

  func testStockLossCarryforwardTracksPreviousCurrentUsedAndNext() throws {
    let carryforward = try StockLossCarryforward(
      fiscalYearID: fiscalYearID,
      sourceYear: 2025,
      broughtForward: Money(yen: 300_000),
      currentYearLoss: Money(yen: 100_000),
      utilized: Money(yen: 250_000)
    )
    XCTAssertEqual(carryforward.carriedForward, Money(yen: 150_000))
    XCTAssertThrowsError(
      try StockLossCarryforward(
        fiscalYearID: fiscalYearID, sourceYear: 2025, broughtForward: Money(yen: 10_000),
        currentYearLoss: .zero, utilized: Money(yen: 20_000)))
  }

  func testAttachmentsDeduplicateAndUnsupportedCaseRemainsInCheck() throws {
    var workspace = FilingWorkspace(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      reviewItems: [
        FilingReviewItem(title: "配当の申告方法", detail: "判断が必要", state: .needsDecision)
      ]
    )
    let attachment = FilingAttachment(
      evidenceDocumentID: UUID(), title: "源泉徴収票", category: "給与")
    workspace.attach(attachment, at: now)
    workspace.attach(attachment, at: now)
    let summary = try FilingAggregation.summary(
      fiscalYearID: fiscalYearID,
      businessIncome: BusinessIncomeSnapshot(
        revenue: .zero, expenses: .zero, income: .zero, generatedAt: now),
      workspace: workspace,
      wages: [], rentalEntries: [], securitiesReports: [], otherIncome: [], deductions: [],
      unsupportedCases: [
        UnsupportedFilingCase(
          fiscalYearID: fiscalYearID, title: "国外所得", guidance: "e-Taxで追加入力")
      ]
    )
    XCTAssertEqual(workspace.attachments.count, 1)
    XCTAssertEqual(summary.attentionCount, 2)
  }

  private func wage(_ payer: String, payment: Int64, tax: Int64) throws
    -> WageWithholdingStatement
  {
    try WageWithholdingStatement(
      fiscalYearID: fiscalYearID,
      payerName: payer,
      paymentAmount: Money(yen: payment),
      withholdingTax: Money(yen: tax),
      socialInsurance: Money(yen: 10_000)
    )
  }
}
