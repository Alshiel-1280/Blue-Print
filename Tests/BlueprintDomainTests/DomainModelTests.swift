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

  func testBalancedJournalPostsAndBuildsConsistentReports() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "rules",
      formRuleSetID: "forms"
    )
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      transactionDate: now,
      description: "売上入金",
      lines: [
        try JournalLine(
          accountID: accounts[0].id,
          side: .debit,
          amount: Money(yen: 50_000)
        ),
        try JournalLine(
          accountID: accounts[8].id,
          side: .credit,
          amount: Money(yen: 50_000)
        ),
      ]
    )

    try entry.post(for: year, at: now)
    XCTAssertEqual(entry.status, .posted)
    let trial = try AccountingReports.trialBalance(entries: [entry])
    XCTAssertTrue(trial.isBalanced)
    XCTAssertEqual(trial.totalDebits, Money(yen: 50_000))
    let cashLedger = try AccountingReports.ledger(accountID: accounts[0].id, entries: [entry])
    XCTAssertEqual(cashLedger.last?.runningBalance, Money(yen: 50_000))
  }

  func testUnbalancedJournalCannotPost() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "rules",
      formRuleSetID: "forms"
    )
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      transactionDate: now,
      description: "不一致",
      lines: [
        try JournalLine(accountID: accounts[0].id, side: .debit, amount: Money(yen: 1_000)),
        try JournalLine(accountID: accounts[8].id, side: .credit, amount: Money(yen: 999)),
      ]
    )

    XCTAssertThrowsError(try entry.post(for: year, at: now)) { error in
      XCTAssertEqual(
        error as? JournalError,
        .debitsAndCreditsDoNotMatch(debits: 1_000, credits: 999)
      )
    }
    XCTAssertEqual(entry.status, .draft)
  }

  func testReversalOffsetsOriginalWithoutLosingTraceability() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "rules",
      formRuleSetID: "forms"
    )
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    var original = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      transactionDate: now,
      description: "消耗品",
      lines: [
        try JournalLine(accountID: accounts[11].id, side: .debit, amount: Money(yen: 3_000)),
        try JournalLine(accountID: accounts[0].id, side: .credit, amount: Money(yen: 3_000)),
      ]
    )
    try original.post(for: year, at: now)
    var reversal = try original.makeReversal(at: now.addingTimeInterval(1), reason: "重複")
    try reversal.post(for: year, at: now.addingTimeInterval(1))

    XCTAssertEqual(reversal.sourceEntryID, original.id)
    let trial = try AccountingReports.trialBalance(entries: [original, reversal])
    XCTAssertTrue(trial.accounts.allSatisfy { $0.net == .zero })
  }

  func testOpeningAndOwnerEquityClosingEntriesBalance() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let fiscalYearID = UUID()
    let opening = try JournalEntry.openingBalance(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      transactionDate: now,
      balances: [
        (accounts[0].id, Money(yen: 100_000)),
        (accounts[3].id, Money(yen: -20_000)),
      ],
      capitalAccountID: accounts[5].id
    )
    XCTAssertEqual(opening.kind, .opening)
    XCTAssertEqual(try opening.totals().debits, Money(yen: 100_000))
    XCTAssertEqual(try opening.totals().credits, Money(yen: 100_000))

    let closing = try JournalEntry.ownerEquityClosing(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      transactionDate: now,
      ownerDrawingsAccountID: accounts[6].id,
      ownerDrawings: Money(yen: 30_000),
      ownerContributionsAccountID: accounts[7].id,
      ownerContributions: Money(yen: 10_000),
      capitalAccountID: accounts[5].id
    )
    XCTAssertEqual(closing.kind, .closing)
    XCTAssertEqual(try closing.totals().debits, try closing.totals().credits)
  }

  func testZeroYenAndDateBoundaryAreRejected() throws {
    let firstDay = Date(timeIntervalSince1970: 1_767_225_600)
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: firstDay),
      calendarYear: 2026,
      taxRuleSetID: "rules",
      formRuleSetID: "forms"
    )
    let accounts = StandardChartOfAccounts.accounts(createdAt: firstDay)
    XCTAssertThrowsError(
      try JournalLine(accountID: accounts[0].id, side: .debit, amount: .zero)
    ) { error in
      XCTAssertEqual(error as? JournalError, .amountMustBePositive)
    }
    var outside = JournalEntry(
      metadata: EntityMetadata(createdAt: firstDay),
      fiscalYearID: year.id,
      transactionDate: Date(timeIntervalSince1970: 1_735_689_600),
      description: "年度外",
      lines: [
        try JournalLine(accountID: accounts[0].id, side: .debit, amount: Money(yen: 1)),
        try JournalLine(accountID: accounts[8].id, side: .credit, amount: Money(yen: 1)),
      ]
    )
    XCTAssertThrowsError(try outside.post(for: year, at: firstDay)) { error in
      XCTAssertEqual(error as? JournalError, .dateOutsideFiscalYear)
    }
  }

  func testCompositeJournalWithThreeLinesBalances() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "rules",
      formRuleSetID: "forms"
    )
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      transactionDate: now,
      description: "複合仕訳",
      lines: [
        try JournalLine(accountID: accounts[0].id, side: .debit, amount: Money(yen: 700)),
        try JournalLine(accountID: accounts[1].id, side: .debit, amount: Money(yen: 300)),
        try JournalLine(accountID: accounts[8].id, side: .credit, amount: Money(yen: 1_000)),
      ]
    )
    try entry.post(for: year, at: now)
    XCTAssertEqual(entry.status, .posted)
  }
}
