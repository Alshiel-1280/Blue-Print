import XCTest

@testable import BlueprintDomain

final class DomainModelTests: XCTestCase {
  func testMoneyUsesIntegerYenAndRejectsOverflow() throws {
    XCTAssertEqual(try Money(yen: 120).adding(Money(yen: 30)), Money(yen: 150))
    XCTAssertEqual(try Money(yen: 120).subtracting(Money(yen: 30)), Money(yen: 90))
    XCTAssertThrowsError(try Money(yen: Int64.max).adding(Money(yen: 1))) { error in
      XCTAssertEqual(error as? MoneyError, .overflow)
    }
    XCTAssertThrowsError(try Money(yen: Int64.max).multiplied(by: 2)) { error in
      XCTAssertEqual(error as? MoneyError, .overflow)
    }
  }

  func testRoundingRulesAreExplicitAndDeterministic() {
    XCTAssertEqual(RoundingRule.down.apply(Decimal(string: "10.9")!), 10)
    XCTAssertEqual(RoundingRule.up.apply(Decimal(string: "10.1")!), 11)
    XCTAssertEqual(RoundingRule.nearest.apply(Decimal(string: "10.5")!), 11)
    XCTAssertEqual(RoundingRule.down.apply(Decimal(string: "-10.9")!), -10)
    XCTAssertEqual(RoundingRule.up.apply(Decimal(string: "-10.1")!), -11)
  }

  func testTaxRateAndInvoiceRegistrationRemainIndependent() {
    XCTAssertEqual(TaxRate.standard10.basisPoints, 1_000)
    XCTAssertEqual(TaxRate.reduced8.basisPoints, 800)
    XCTAssertNil(TaxRate.exempt.basisPoints)
    XCTAssertNotEqual(TaxRate.standard10.rawValue, InvoiceRegistrationStatus.qualified.rawValue)
  }

  func testFiscalYearStateAndReopenReasonBoundary() throws {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    var year = try FiscalYear(
      metadata: EntityMetadata(createdAt: createdAt),
      calendarYear: 2026,
      taxRuleSetID: "rules-2026",
      formRuleSetID: "forms-2026"
    )
    XCTAssertEqual(year.status, .open)

    let lockedAt = createdAt.addingTimeInterval(60)
    year.lock(at: lockedAt)
    XCTAssertEqual(year.status, .locked)
    XCTAssertEqual(year.lockedAt, lockedAt)

    XCTAssertThrowsError(try year.reopen(reason: "  ", at: lockedAt)) { error in
      XCTAssertEqual(error as? FiscalYearError, .missingReopenReason)
    }
    try year.reopen(reason: "修正申告の準備", at: lockedAt.addingTimeInterval(60))
    XCTAssertEqual(year.status, .open)
    XCTAssertNil(year.lockedAt)
  }

  func testFiscalYearRejectsUnsupportedBoundary() {
    XCTAssertThrowsError(
      try FiscalYear(
        metadata: EntityMetadata(createdAt: Date()),
        calendarYear: 1999,
        taxRuleSetID: "rules",
        formRuleSetID: "forms"
      )
    ) { error in
      XCTAssertEqual(error as? FiscalYearError, .unsupportedCalendarYear(1999))
    }
  }

  func testStandardChartHasUniqueStableCodesAndRequiredOwnerAccounts() {
    let first = StandardChartOfAccounts.accounts(createdAt: Date(timeIntervalSince1970: 1))
    let second = StandardChartOfAccounts.accounts(createdAt: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(Set(first.map(\.code)).count, first.count)
    XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertTrue(first.contains { $0.name == "事業主貸" })
    XCTAssertTrue(first.contains { $0.name == "事業主借" })
    XCTAssertTrue(first.contains { $0.name == "元入金" })
  }

  func testAccountDeactivationPreservesIdentity() {
    let createdAt = Date(timeIntervalSince1970: 1)
    let deactivatedAt = Date(timeIntervalSince1970: 2)
    var account = StandardChartOfAccounts.accounts(createdAt: createdAt)[0]
    let id = account.id
    account.deactivate(at: deactivatedAt)
    XCTAssertFalse(account.isActive)
    XCTAssertEqual(account.id, id)
    XCTAssertEqual(account.metadata.updatedAt, deactivatedAt)
  }
}
