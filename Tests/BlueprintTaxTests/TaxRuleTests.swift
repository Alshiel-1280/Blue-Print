import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintClosing
@testable import BlueprintFiling
@testable import BlueprintTax

final class TaxRuleTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  func testOfficial2025RulesCarryEffectivePeriodSourcesAndETaxVersions() throws {
    let (tax, form) = try OfficialRules2025.catalog.rules(for: 2025)

    XCTAssertEqual(tax.id, "tax-2025.1")
    XCTAssertEqual(tax.blueReturnDeduction.electronicMaximum, Money(yen: 650_000))
    XCTAssertEqual(form.procedureID, "RKO0010")
    XCTAssertEqual(form.procedureVersion, "25.0.0")
    XCTAssertEqual(form.forms.map(\.id), ["KOA020", "KOA210", "KOA220"])
    XCTAssertEqual(form.forms.map(\.version), ["23.0", "11.0", "8.0"])
    XCTAssertTrue(tax.sources.allSatisfy { !$0.url.isEmpty })
    XCTAssertTrue(form.sources.allSatisfy { !$0.url.isEmpty })
  }

  func testAddingNewYearKeepsExistingRulesImmutableAndShowsAffectedItems() throws {
    let old = OfficialRules2025.form
    let new = FormRuleSet(
      id: "form-2026.1",
      revision: "2026.1",
      effectivePeriod: try RuleEffectivePeriod(firstYear: 2026, lastYear: 2026),
      procedureID: "RKO0010",
      procedureVersion: "26.0.0",
      forms: old.forms,
      fields: old.fields + [
        ETaxFieldDefinition(tag: "NEW00010", label: "新年度項目", dataType: .integer)
      ],
      sources: old.sources
    )
    let newTax = TaxRuleSet(
      id: "tax-2026.1",
      revision: "2026.1",
      effectivePeriod: try RuleEffectivePeriod(firstYear: 2026, lastYear: 2026),
      blueReturnDeduction: OfficialRules2025.tax.blueReturnDeduction,
      sources: OfficialRules2025.tax.sources
    )
    let catalog = try OfficialRules2025.catalog.adding(taxRuleSet: newTax, formRuleSet: new)

    XCTAssertEqual(try catalog.rules(for: 2025).1, old)
    XCTAssertEqual(try catalog.rules(for: 2026).1, new)
    XCTAssertEqual(
      RuleCatalog.difference(from: old, to: new).affectedItems,
      ["項目追加: 新年度項目"]
    )
    XCTAssertThrowsError(
      try catalog.adding(taxRuleSet: newTax, formRuleSet: new)
    )
  }

  func testBlueReturnMappingReconcilesStatementsAndAssessesElectronicDeduction() throws {
    let revenueAccount = UUID()
    let expenseAccount = UUID()
    let assetAccount = UUID()
    let profitAndLoss = ProfitAndLossReport(
      period: now...now,
      revenue: [
        ReportAccountAmount(
          accountID: revenueAccount,
          accountCode: "4000",
          accountName: "売上高",
          amount: Money(yen: 1_000_000)
        )
      ],
      expenses: [
        ReportAccountAmount(
          accountID: expenseAccount,
          accountCode: "5100",
          accountName: "仕入高",
          amount: Money(yen: 300_000)
        )
      ],
      totalRevenue: Money(yen: 1_000_000),
      totalExpenses: Money(yen: 300_000),
      profit: Money(yen: 700_000)
    )
    let balanceSheet = BalanceSheetReport(
      asOf: now,
      assets: [
        ReportAccountAmount(
          accountID: assetAccount,
          accountCode: "1100",
          accountName: "普通預金",
          amount: Money(yen: 700_000)
        )
      ],
      liabilities: [],
      equity: [],
      totalAssets: Money(yen: 700_000),
      totalLiabilitiesAndEquity: Money(yen: 700_000),
      currentProfit: Money(yen: 700_000)
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: UUID(),
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      taxOffice: "麹町税務署"
    )
    let package = BlueReturnMapper.make(
      fiscalYear: 2025,
      profile: profile,
      profitAndLoss: profitAndLoss,
      balanceSheet: balanceSheet,
      businessSnapshot: BusinessIncomeSnapshot(
        revenue: Money(yen: 1_000_000),
        expenses: Money(yen: 300_000),
        income: Money(yen: 700_000),
        generatedAt: now
      ),
      propertyReport: PropertyIncomeReport(
        revenue: Money(yen: 500_000),
        expenses: Money(yen: 100_000),
        depreciation: Money(yen: 50_000),
        income: Money(yen: 350_000)
      )
    )
    let assessment = BlueReturnMapper.deductionAssessment(
      profile: profile,
      balanceSheet: balanceSheet,
      taxRuleSet: OfficialRules2025.tax,
      intendsElectronicFiling: true
    )

    XCTAssertTrue(package.validationIssues.isEmpty)
    XCTAssertEqual(package.business.incomeBeforeDeduction, Money(yen: 700_000))
    XCTAssertEqual(package.property.incomeBeforeDeduction, Money(yen: 350_000))
    XCTAssertEqual(assessment.candidateAmount, Money(yen: 650_000))
    XCTAssertTrue(assessment.isEligible)
    XCTAssertTrue(BlueReturnMapper.preview(package).contains("資産合計 700000円"))
  }
}
