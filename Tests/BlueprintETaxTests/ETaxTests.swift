import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintETax
@testable import BlueprintFiling
@testable import BlueprintTax

final class ETaxTests: XCTestCase {
  private let fiscalYearID = UUID()
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  func testInvalidRequiredFieldStopsXTXBeforeGeneration() throws {
    let blueReturn = makeBlueReturn()
    var data = makeReturn(blueReturn: blueReturn)
    let koa020 = data.forms[0]
    data = ETaxReturnData(
      fiscalYear: data.fiscalYear,
      procedureID: data.procedureID,
      procedureVersion: data.procedureVersion,
      taxRuleSetID: data.taxRuleSetID,
      formRuleSetID: data.formRuleSetID,
      identity: data.identity,
      forms: [
        ETaxFormData(
          formID: koa020.formID,
          version: koa020.version,
          fields: koa020.fields.filter { $0.tag != "ABA00030" }
        )
      ] + Array(data.forms.dropFirst()),
      checklist: data.checklist,
      ledgerFingerprint: data.ledgerFingerprint
    )
    let issues = ETaxValidator.validate(data, rules: OfficialRules2025.form, blueReturn: blueReturn)

    XCTAssertTrue(issues.contains { $0.fieldTag == "ABA00030" && $0.severity == .error })
    XCTAssertThrowsError(try XTXGenerator.generate(data, validationIssues: issues))
  }

  func testGeneratedXTXUsesOfficialProcedureAndFormVersions() throws {
    let blueReturn = makeBlueReturn()
    let data = makeReturn(blueReturn: blueReturn)
    let issues = ETaxValidator.validate(data, rules: OfficialRules2025.form, blueReturn: blueReturn)
    let package = try XTXGenerator.generate(data, validationIssues: issues)
    let xml = String(decoding: package.data, as: UTF8.self)

    XCTAssertTrue(issues.isEmpty)
    XCTAssertEqual(package.fileName, "blue-print-2025.xtx")
    XCTAssertEqual(package.hash.count, 64)
    XCTAssertTrue(xml.contains("<RKO0010 VR=\"25.0.0\""))
    XCTAssertTrue(xml.contains("<KOA020 VR=\"23.0\""))
    XCTAssertTrue(xml.contains("<KOA210 VR=\"11.0\""))
    XCTAssertTrue(xml.contains("<KOA220 VR=\"8.0\""))
    XCTAssertFalse(xml.contains("Signature"))
    if let outputPath = ProcessInfo.processInfo.environment["BLUEPRINT_XTX_OUTPUT"] {
      try package.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
  }

  func testAdditionalInputChecklistSurvivesExportAndLedgerChangeMarksStale() throws {
    let blueReturn = makeBlueReturn()
    let data = makeReturn(blueReturn: blueReturn)
    let package = try XTXGenerator.generate(data, validationIssues: [])
    let record = ETaxExportRecord(
      fiscalYearID: fiscalYearID,
      exportedAt: now,
      fileName: package.fileName,
      fileHash: package.hash,
      taxRuleSetID: data.taxRuleSetID,
      formRuleSetID: data.formRuleSetID,
      schemaVersion: data.procedureVersion,
      ledgerFingerprint: data.ledgerFingerprint,
      checklist: data.checklist
    )

    XCTAssertTrue(record.checklist.contains { $0.state == .additionalInput })
    XCTAssertFalse(record.needsRegeneration(currentLedgerFingerprint: data.ledgerFingerprint))
    XCTAssertTrue(record.needsRegeneration(currentLedgerFingerprint: "changed"))
  }

  func testOfficialGeneralBlueReturnExampleMapsToKOA210Values() throws {
    // 令和7年分「青色申告決算書（一般用）の書き方」3ページの記載例。
    let example = BlueReturnPackage(
      business: BusinessBlueReturnStatement(
        fiscalYear: 2025,
        ownerName: "国税 太郎",
        tradeName: "記載例",
        revenueLines: [],
        expenseLines: [],
        assetLines: [],
        liabilityAndEquityLines: [],
        totalRevenue: Money(yen: 39_280_000),
        totalExpenses: Money(yen: 35_158_280),
        incomeBeforeDeduction: Money(yen: 4_121_720),
        totalAssets: Money(yen: 14_000_000),
        totalLiabilitiesAndEquity: Money(yen: 14_000_000)
      ),
      property: PropertyBlueReturnStatement(
        fiscalYear: 2025,
        revenue: .zero,
        expenses: .zero,
        depreciation: .zero,
        incomeBeforeDeduction: .zero
      ),
      validationIssues: []
    )
    let data = ETaxMapper.make(
      fiscalYear: 2025,
      profile: makeProfile(ownerName: "国税 太郎"),
      blueReturn: example,
      deductionAssessment: BlueReturnDeductionAssessment(
        candidateAmount: Money(yen: 550_000), missingRequirements: []),
      filingSummary: FilingWorkspaceSummary(
        businessIncome: BusinessIncomeSnapshot(
          revenue: Money(yen: 39_280_000),
          expenses: Money(yen: 35_158_280),
          income: Money(yen: 4_121_720),
          generatedAt: now
        ),
        propertyIncome: .zero,
        wageRevenue: .zero,
        securitiesIncome: .zero,
        otherIncome: .zero,
        withholdingTax: .zero,
        deductions: .zero,
        attentionCount: 0
      ),
      deductions: [],
      unsupportedCases: [],
      taxRuleSet: OfficialRules2025.tax,
      formRuleSet: OfficialRules2025.form,
      ledgerFingerprint: "official-example"
    )
    let business = try XCTUnwrap(data.forms.first { $0.formID == "KOA210" })
    let values = Dictionary(uniqueKeysWithValues: business.fields.map { ($0.tag, $0.value) })

    XCTAssertEqual(values["AMF00100"], "39280000")
    XCTAssertEqual(values["AMF00500"], "4121720")
    XCTAssertEqual(values["AMF00510"], "550000")
    XCTAssertEqual(values["AMF00530"], "3571720")
  }

  private func makeReturn(blueReturn: BlueReturnPackage) -> ETaxReturnData {
    ETaxMapper.make(
      fiscalYear: 2025,
      profile: makeProfile(),
      blueReturn: blueReturn,
      deductionAssessment: BlueReturnDeductionAssessment(
        candidateAmount: Money(yen: 650_000),
        missingRequirements: []
      ),
      filingSummary: FilingWorkspaceSummary(
        businessIncome: BusinessIncomeSnapshot(
          revenue: Money(yen: 1_000_000),
          expenses: Money(yen: 300_000),
          income: Money(yen: 700_000),
          generatedAt: now
        ),
        propertyIncome: Money(yen: 350_000),
        wageRevenue: Money(yen: 0),
        securitiesIncome: Money(yen: 0),
        otherIncome: Money(yen: 0),
        withholdingTax: Money(yen: 0),
        deductions: Money(yen: 0),
        attentionCount: 1
      ),
      deductions: [],
      unsupportedCases: [
        UnsupportedFilingCase(
          fiscalYearID: fiscalYearID,
          title: "外国税額控除",
          guidance: "e-Tax WEB版で追加入力してください。"
        )
      ],
      taxRuleSet: OfficialRules2025.tax,
      formRuleSet: OfficialRules2025.form,
      ledgerFingerprint: XTXGenerator.ledgerFingerprint(parts: ["2025", "700000"])
    )
  }

  private func makeProfile(ownerName: String = "青空 花子") -> BusinessProfile {
    BusinessProfile(
      metadata: EntityMetadata(id: UUID(), createdAt: now, updatedAt: now),
      fiscalYearID: fiscalYearID,
      ownerName: ownerName,
      tradeName: "青空デザイン",
      postalAddress: "東京都千代田区千代田1-1",
      taxAddress: "東京都千代田区千代田1-1",
      taxOffice: "麹町税務署",
      taxOfficeCode: "01101",
      eTaxUserID: "1234567890123456"
    )
  }

  private func makeBlueReturn() -> BlueReturnPackage {
    BlueReturnPackage(
      business: BusinessBlueReturnStatement(
        fiscalYear: 2025,
        ownerName: "青空 花子",
        tradeName: "青空デザイン",
        revenueLines: [],
        expenseLines: [],
        assetLines: [],
        liabilityAndEquityLines: [],
        totalRevenue: Money(yen: 1_000_000),
        totalExpenses: Money(yen: 300_000),
        incomeBeforeDeduction: Money(yen: 700_000),
        totalAssets: Money(yen: 700_000),
        totalLiabilitiesAndEquity: Money(yen: 700_000)
      ),
      property: PropertyBlueReturnStatement(
        fiscalYear: 2025,
        revenue: Money(yen: 500_000),
        expenses: Money(yen: 100_000),
        depreciation: Money(yen: 50_000),
        incomeBeforeDeduction: Money(yen: 350_000)
      ),
      validationIssues: []
    )
  }
}
