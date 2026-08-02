import BlueprintDomain
import CryptoKit
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

  func testBundledRulePackagesSeparate2026BookkeepingFromFilingSupport() throws {
    XCTAssertEqual(OfficialRulePackages.supportedYears, [2025, 2026])

    let support2025 = try XCTUnwrap(OfficialRulePackages.store.support(for: 2025))
    XCTAssertTrue(support2025.supports(.bookkeeping))
    XCTAssertTrue(support2025.supports(.incomeTaxForm))
    XCTAssertTrue(support2025.supports(.xtx))

    let support2026 = try XCTUnwrap(OfficialRulePackages.store.support(for: 2026))
    XCTAssertTrue(support2026.supports(.bookkeeping))
    XCTAssertTrue(support2026.supports(.consumptionTax))
    XCTAssertTrue(support2026.supports(.closing))
    XCTAssertFalse(support2026.supports(.incomeTaxForm))
    XCTAssertFalse(support2026.supports(.xtx))
    XCTAssertEqual(try OfficialRulePackages.store.taxRule(for: 2026).id, "tax-2026.1")
    XCTAssertThrowsError(try OfficialRulePackages.store.formRule(for: 2026))

    let transition = try XCTUnwrap(
      try OfficialRulePackages.store.package(for: 2026).payload.invoiceDeductionRules.first {
        $0.firstTransactionDate == "2026-10-01"
      })
    XCTAssertEqual(transition.deductibleRateBasisPoints, 7_000)
    XCTAssertEqual(transition.annualSupplierPurchaseLimitYen, 100_000_000)
    XCTAssertEqual(
      transition.limitAppliesToTaxPeriodsStartingOnOrAfter,
      "2026-10-01"
    )
  }

  func testInvoiceDeductionEvaluatesIndependentBoundaryInputs() throws {
    let rules = try OfficialRulePackages.store.package(for: 2026).payload.invoiceDeductionRules
    func decision(
      transaction: String,
      period: String,
      purchases: Int64,
      registration: InvoiceRegistrationStatus,
      rate: TaxRate
    ) -> Int {
      InvoiceDeductionEvaluator.evaluate(
        context: InvoiceDeductionContext(
          transactionDate: Self.date(transaction),
          taxPeriodStart: Self.date(period),
          supplierAnnualPurchasesYen: purchases,
          invoiceStatus: registration,
          taxRate: rate
        ),
        rules: rules
      ).deductibleRateBasisPoints
    }

    XCTAssertEqual(
      decision(
        transaction: "2026-09-30",
        period: "2026-01-01",
        purchases: 150_000_000,
        registration: .exemptOrUnregistered,
        rate: .standard10
      ),
      8_000
    )
    XCTAssertEqual(
      decision(
        transaction: "2026-10-01",
        period: "2026-01-01",
        purchases: 150_000_000,
        registration: .exemptOrUnregistered,
        rate: .reduced8
      ),
      7_000
    )
    XCTAssertEqual(
      decision(
        transaction: "2026-10-01",
        period: "2026-10-01",
        purchases: 100_000_001,
        registration: .exemptOrUnregistered,
        rate: .standard10
      ),
      0
    )
    XCTAssertEqual(
      decision(
        transaction: "2026-10-01",
        period: "2026-10-01",
        purchases: 500_000_000,
        registration: .qualified,
        rate: .standard10
      ),
      10_000
    )
    XCTAssertEqual(
      decision(
        transaction: "2026-10-01",
        period: "2026-10-01",
        purchases: 1,
        registration: .qualified,
        rate: .outOfScope
      ),
      0
    )
  }

  func testRulePackageVerifierRejectsTamperingAndUnknownKeys() throws {
    let key = Curve25519.Signing.PrivateKey()
    let payload = RulePackagePayload(
      taxRuleSet: OfficialRules2025.tax,
      formRuleSet: OfficialRules2025.form
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let payloadData = try encoder.encode(payload)
    let manifest = RulePackageManifest(
      schemaVersion: 1,
      packageID: "test-package",
      calendarYear: 2025,
      revision: "2025.99",
      scopes: [.bookkeeping, .incomeTaxForm, .xtx],
      minimumAppVersion: "1.1.0",
      payloadSHA256: RulePackageVerifier.sha256(payloadData),
      keyID: "test-key"
    )
    let manifestData = try encoder.encode(manifest)
    let signature = try key.signature(for: manifestData)
    let verifier = RulePackageVerifier(
      trustedKeys: [
        TrustedRuleKey(id: "test-key", rawRepresentation: key.publicKey.rawRepresentation)
      ])

    guard
      case .verified = verifier.verify(
        manifestData: manifestData,
        payloadData: payloadData,
        signatureData: signature,
        origin: .bundled
      )
    else {
      return XCTFail("Expected a verified package")
    }

    var tamperedPayload = payloadData
    tamperedPayload[tamperedPayload.startIndex] ^= 0x01
    XCTAssertEqual(
      verifier.verify(
        manifestData: manifestData,
        payloadData: tamperedPayload,
        signatureData: signature,
        origin: .bundled
      ),
      .rejected(.invalidPayloadHash)
    )

    let unknownKeyManifest = RulePackageManifest(
      schemaVersion: manifest.schemaVersion,
      packageID: manifest.packageID,
      calendarYear: manifest.calendarYear,
      revision: manifest.revision,
      scopes: manifest.scopes,
      minimumAppVersion: manifest.minimumAppVersion,
      payloadSHA256: manifest.payloadSHA256,
      keyID: "unknown"
    )
    let unknownManifestData = try encoder.encode(unknownKeyManifest)
    XCTAssertEqual(
      verifier.verify(
        manifestData: unknownManifestData,
        payloadData: payloadData,
        signatureData: try key.signature(for: unknownManifestData),
        origin: .installed
      ),
      .rejected(.unknownKey("unknown"))
    )
    XCTAssertEqual(
      verifier.verify(
        manifestData: manifestData,
        payloadData: payloadData,
        signatureData: Data(),
        origin: .installed
      ),
      .rejected(.invalidSignature)
    )
  }

  func testRuleCatalogRejectsMissingSignatureDowngradeAndUnsupportedYear() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BluePrintRuleCatalog-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = root.appendingPathComponent("Bundled", isDirectory: true)
    let installed = root.appendingPathComponent("Installed", isDirectory: true)
    try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    let trusted = TrustedRuleKey(
      id: "test-key",
      rawRepresentation: key.publicKey.rawRepresentation
    )

    try writeRulePackage(
      to: bundled,
      name: "2025.bprules",
      packageID: "rules-2025.2",
      revision: "2025.2",
      key: key
    )
    let store = try RuleCatalogStore(
      bundledDirectory: bundled,
      trustedKeys: [trusted]
    )
    XCTAssertThrowsError(try store.package(for: 2024)) { error in
      XCTAssertEqual(error as? RuleSetError, .unsupportedYear(2024))
    }

    try writeRulePackage(
      to: installed,
      name: "2025.bprules",
      packageID: "rules-2025.1",
      revision: "2025.1",
      key: key
    )
    XCTAssertThrowsError(
      try RuleCatalogStore(
        bundledDirectory: bundled,
        installedDirectory: installed,
        trustedKeys: [trusted]
      )
    ) { error in
      XCTAssertEqual(
        error as? RulePackageVerificationFailure,
        .downgradeAttempt(current: "2025.2", candidate: "2025.1")
      )
    }

    let missingRoot = root.appendingPathComponent("Missing", isDirectory: true)
    try writeRulePackage(
      to: missingRoot,
      name: "2025.bprules",
      packageID: "rules-2025.missing",
      revision: "2025.3",
      key: key,
      includeSignature: false
    )
    XCTAssertThrowsError(
      try RuleCatalogStore(
        bundledDirectory: missingRoot,
        trustedKeys: [trusted]
      )
    ) { error in
      XCTAssertEqual(
        error as? RulePackageVerificationFailure,
        .missingFile("signature.ed25519")
      )
    }
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

  private static func date(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)!
  }

  private func writeRulePackage(
    to parent: URL,
    name: String,
    packageID: String,
    revision: String,
    key: Curve25519.Signing.PrivateKey,
    includeSignature: Bool = true
  ) throws {
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = RulePackagePayload(
      taxRuleSet: OfficialRules2025.tax,
      formRuleSet: OfficialRules2025.form
    )
    let payloadData = try encoder.encode(payload)
    let manifest = RulePackageManifest(
      schemaVersion: 1,
      packageID: packageID,
      calendarYear: 2025,
      revision: revision,
      scopes: [.bookkeeping, .incomeTaxForm, .xtx],
      minimumAppVersion: "1.1.0",
      payloadSHA256: RulePackageVerifier.sha256(payloadData),
      keyID: "test-key"
    )
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(
      to: directory.appendingPathComponent("manifest.json"),
      options: .atomic
    )
    try payloadData.write(
      to: directory.appendingPathComponent("payload.json"),
      options: .atomic
    )
    if includeSignature {
      try Data(try key.signature(for: manifestData).base64EncodedString().utf8)
        .write(
          to: directory.appendingPathComponent("signature.ed25519"),
          options: .atomic
        )
    }
  }
}
