import BlueprintBilling
import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V04PersistenceTests: XCTestCase {
  private var root: URL!
  private var preservesRoot = false
  private var databaseURL: URL { root.appendingPathComponent("Database/blueprint.sqlite") }
  private var backupDirectory: URL { root.appendingPathComponent("Backups") }
  private let now = Date(timeIntervalSince1970: 1_785_000_000)

  override func setUpWithError() throws {
    if let path = ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] {
      root = URL(fileURLWithPath: path, isDirectory: true)
      preservesRoot = true
    } else {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BluePrintV04-\(UUID().uuidString)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root, !preservesRoot { try? FileManager.default.removeItem(at: root) }
  }

  func testVersion4MigratesToBillingSchemaWithBackupAndDataPreserved() throws {
    try SampleDatabaseFactory.makeVersion4Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )

    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 7)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'invoices'"
      ),
      1
    )
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v4-to-v7"))
  }

  func testGenerateQAFixtureWhenConfigured() throws {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_QA_DATA_ROOT"] != nil else { return }
    let context = try billingContext()
    let issueAccounts = InvoiceIssueAccounts(
      receivableAccountID: try account("1200", in: context.database).id,
      revenueAccountID: try account("4000", in: context.database).id
    )
    let overdueDraft = try Invoice(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: context.fiscalYear.id,
      counterpartyID: context.counterparty.id,
      number: "INV-2026-0041",
      issueDate: now.addingTimeInterval(-86_400 * 45),
      dueDate: now.addingTimeInterval(-86_400 * 15),
      subject: "ブランドサイト制作",
      lines: [
        try InvoiceLine(
          description: "設計・デザイン・実装",
          quantity: 1,
          unitPrice: Money(yen: 320_000),
          taxRate: .standard10
        )
      ],
      issuerName: "青空デザイン",
      issuerAddress: "東京都渋谷区神南1-1",
      issuerRegistrationStatus: .qualified,
      issuerRegistrationNumber: "T1234567890123"
    )
    _ = try context.database.issueInvoice(overdueDraft, accounts: issueAccounts, at: now)
    let current = try context.database.issueInvoice(
      makeInvoice(context: context, number: "INV-2026-0042"),
      accounts: issueAccounts,
      at: now
    )
    _ = try context.database.settleInvoice(
      invoiceID: current.id,
      settlement: InvoiceSettlement(
        receivedAt: now,
        appliedAmount: Money(yen: 55_000),
        cashReceived: Money(yen: 54_450),
        bankFee: Money(yen: 550)
      ),
      accounts: try receivableAccounts(context.database),
      at: now
    )
    let vendor = Counterparty(
      metadata: EntityMetadata(createdAt: now),
      code: "V001",
      displayName: "合同会社ノーススタジオ",
      roles: [.vendor],
      invoiceRegistrationStatus: .qualified,
      invoiceRegistrationNumber: "T9876543210123"
    )
    try context.database.saveCounterparty(vendor, at: now)
    let bill = try VendorBill(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: context.fiscalYear.id,
      vendorID: vendor.id,
      referenceNumber: "NS-2607-18",
      issueDate: now,
      dueDate: now.addingTimeInterval(86_400 * 20),
      description: "UIデザイン外注費",
      lines: [
        try InvoiceLine(
          description: "画面設計 8画面",
          quantity: 1,
          unitPrice: Money(yen: 180_000),
          taxRate: .standard10
        )
      ],
      invoiceStatus: .qualified
    )
    _ = try context.database.confirmVendorBill(
      bill,
      accounts: VendorBillAccounts(
        expenseAccountID: try account("5100", in: context.database).id,
        payableAccountID: try account("2100", in: context.database).id
      ),
      at: now
    )
  }

  func testInvoiceIssueIsIdempotentAndPartialSettlementKeepsBalance() throws {
    let context = try billingContext()
    let invoice = try makeInvoice(context: context, number: "INV-2026-0001")
    let issueAccounts = InvoiceIssueAccounts(
      receivableAccountID: try account("1200", in: context.database).id,
      revenueAccountID: try account("4000", in: context.database).id
    )

    let first = try context.database.issueInvoice(invoice, accounts: issueAccounts, at: now)
    let second = try context.database.issueInvoice(invoice, accounts: issueAccounts, at: now)
    XCTAssertEqual(first.journalEntryID, second.journalEntryID)
    XCTAssertEqual(first.evidenceID, second.evidenceID)
    XCTAssertEqual(try context.database.billing.invoices(BillingSearch()).count, 1)
    XCTAssertEqual(
      try context.database.journals.search(
        JournalSearch(fiscalYearID: context.fiscalYear.id)
      ).count,
      1
    )

    let settlement = try InvoiceSettlement(
      receivedAt: now,
      appliedAmount: Money(yen: 55_000),
      cashReceived: Money(yen: 54_450),
      bankFee: Money(yen: 550)
    )
    let settled = try context.database.settleInvoice(
      invoiceID: first.id,
      settlement: settlement,
      accounts: try receivableAccounts(context.database),
      at: now.addingTimeInterval(1)
    )
    XCTAssertEqual(settled.status, .partiallyPaid)
    XCTAssertEqual(try settled.outstandingAmount(), Money(yen: 55_000))
  }

  func testReissueKeepsOriginalPDFAndCancellationCreatesTraceableReversal() throws {
    let context = try billingContext()
    let invoice = try makeInvoice(context: context, number: "INV-2026-0002")
    let issued = try context.database.issueInvoice(
      invoice,
      accounts: InvoiceIssueAccounts(
        receivableAccountID: try account("1200", in: context.database).id,
        revenueAccountID: try account("4000", in: context.database).id
      ),
      at: now
    )
    let reissue = try context.database.reissueInvoice(
      id: issued.id,
      reason: "送付先変更による再送",
      at: now.addingTimeInterval(1)
    )
    XCTAssertNotEqual(reissue.evidenceID, issued.evidenceID)
    XCTAssertNotNil(try context.database.evidence.fetch(id: try XCTUnwrap(issued.evidenceID)))
    XCTAssertNotNil(try context.database.evidence.fetch(id: reissue.evidenceID))
    XCTAssertEqual(try context.database.billing.reissues(invoiceID: issued.id).count, 1)

    let cancelled = try context.database.cancelInvoice(
      id: issued.id,
      reason: "取引取消",
      at: now.addingTimeInterval(2)
    )
    XCTAssertEqual(cancelled.status, .cancelled)
    let entries = try context.database.journals.search(
      JournalSearch(fiscalYearID: context.fiscalYear.id)
    )
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries.first { $0.id == issued.journalEntryID }?.status, .reversed)
    XCTAssertNotNil(entries.first { $0.sourceEntryID == issued.journalEntryID })
  }

  func testCorrectionAndRefundTrackOriginalWithOppositeRefundJournal() throws {
    let context = try billingContext()
    let issueAccounts = InvoiceIssueAccounts(
      receivableAccountID: try account("1200", in: context.database).id,
      revenueAccountID: try account("4000", in: context.database).id
    )
    let original = try context.database.issueInvoice(
      makeInvoice(context: context, number: "INV-2026-0003"),
      accounts: issueAccounts,
      at: now
    )
    let correctedDraft = try original.correction(
      metadata: EntityMetadata(createdAt: now.addingTimeInterval(1)),
      number: "INV-2026-0003-C1",
      lines: [
        try InvoiceLine(
          description: "訂正後制作費",
          quantity: 1,
          unitPrice: Money(yen: 90_000),
          taxRate: .standard10
        )
      ],
      reason: "数量訂正"
    )
    let correction = try context.database.issueInvoice(
      correctedDraft,
      accounts: issueAccounts,
      at: now.addingTimeInterval(1)
    )
    XCTAssertEqual(correction.sourceInvoiceID, original.id)
    XCTAssertEqual(try context.database.billing.invoice(id: original.id)?.status, .corrected)

    let refundDraft = try Invoice(
      metadata: EntityMetadata(createdAt: now.addingTimeInterval(2)),
      fiscalYearID: context.fiscalYear.id,
      counterpartyID: context.counterparty.id,
      number: "INV-2026-0003-R1",
      issueDate: now,
      dueDate: now,
      subject: "返金",
      kind: .refund,
      lines: [
        try InvoiceLine(
          description: "返金対象",
          quantity: 1,
          unitPrice: Money(yen: 10_000),
          taxRate: .standard10
        )
      ],
      issuerName: "青空デザイン",
      issuerAddress: "東京都渋谷区神南1-1",
      issuerRegistrationStatus: .qualified,
      issuerRegistrationNumber: "T1234567890123",
      sourceInvoiceID: original.id,
      reason: "一部返金"
    )
    let refund = try context.database.issueInvoice(
      refundDraft,
      accounts: issueAccounts,
      at: now.addingTimeInterval(2)
    )
    let refundJournal = try XCTUnwrap(
      try context.database.journals.fetch(id: try XCTUnwrap(refund.journalEntryID))
    )
    XCTAssertEqual(refund.sourceInvoiceID, original.id)
    XCTAssertEqual(try context.database.billing.invoice(id: original.id)?.status, .refunded)
    XCTAssertEqual(refundJournal.lines.first?.side, .credit)
    XCTAssertEqual(refundJournal.lines.last?.side, .debit)
    let revenueID = try account("4000", in: context.database).id
    let entries = try context.database.journals.search(
      JournalSearch(fiscalYearID: context.fiscalYear.id)
    )
    let revenueCredits = entries.flatMap(\.lines).filter {
      $0.accountID == revenueID && $0.side == .credit
    }.reduce(0) { $0 + $1.amount.yen }
    let revenueDebits = entries.flatMap(\.lines).filter {
      $0.accountID == revenueID && $0.side == .debit
    }.reduce(0) { $0 + $1.amount.yen }
    XCTAssertEqual(revenueCredits - revenueDebits, 88_000)
  }

  func testCombinedReceiptSettlesMultipleInvoicesInOneJournal() throws {
    let context = try billingContext()
    let accounts = InvoiceIssueAccounts(
      receivableAccountID: try account("1200", in: context.database).id,
      revenueAccountID: try account("4000", in: context.database).id
    )
    let first = try context.database.issueInvoice(
      makeInvoice(context: context, number: "INV-2026-0010"),
      accounts: accounts,
      at: now
    )
    let second = try context.database.issueInvoice(
      makeInvoice(context: context, number: "INV-2026-0011"),
      accounts: accounts,
      at: now
    )
    let journalsBefore = try context.database.journals.search(
      JournalSearch(fiscalYearID: context.fiscalYear.id)
    ).count
    let settled = try context.database.settleInvoices(
      allocations: [
        (first.id, Money(yen: 110_000)),
        (second.id, Money(yen: 110_000)),
      ],
      bankAccountID: try account("1100", in: context.database).id,
      receivableAccountID: try account("1200", in: context.database).id,
      at: now.addingTimeInterval(1)
    )
    XCTAssertEqual(settled.map(\.status), [.paid, .paid])
    XCTAssertEqual(
      try context.database.journals.search(
        JournalSearch(fiscalYearID: context.fiscalYear.id)
      ).count,
      journalsBefore + 1
    )
    XCTAssertEqual(Set(settled.compactMap { $0.settlements.first?.journalEntryID }).count, 1)
  }

  func testVendorPartialPaymentAndOverdueSearchPreserveOutstanding() throws {
    let context = try billingContext()
    let bill = try VendorBill(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: context.fiscalYear.id,
      vendorID: context.counterparty.id,
      referenceNumber: "V-2026-01",
      issueDate: now.addingTimeInterval(-86_400 * 40),
      dueDate: now.addingTimeInterval(-86_400),
      description: "制作外注費",
      lines: [
        try InvoiceLine(
          description: "デザイン制作",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      invoiceStatus: .qualified
    )
    let confirmed = try context.database.confirmVendorBill(
      bill,
      accounts: VendorBillAccounts(
        expenseAccountID: try account("5100", in: context.database).id,
        payableAccountID: try account("2100", in: context.database).id
      ),
      at: now
    )
    let payment = try VendorBillPayment(
      paidAt: now,
      appliedAmount: Money(yen: 44_000),
      cashPaid: Money(yen: 44_000)
    )
    let paid = try context.database.settleVendorBill(
      billID: confirmed.id,
      payment: payment,
      accounts: VendorPaymentAccounts(
        payableAccountID: try account("2100", in: context.database).id,
        bankAccountID: try account("1100", in: context.database).id,
        bankFeeAccountID: try account("5500", in: context.database).id,
        withholdingAccountID: try account("2000", in: context.database).id
      ),
      at: now.addingTimeInterval(1)
    )
    XCTAssertFalse(paid.withholdingEnabled)
    XCTAssertEqual(paid.status, .partiallyPaid)
    XCTAssertEqual(try paid.outstandingAmount(), Money(yen: 66_000))
    XCTAssertEqual(
      try context.database.billing.vendorBills(BillingSearch(overdueAsOf: now)).map(\.id),
      [bill.id]
    )
  }

  private func billingContext() throws -> (
    database: BlueprintDatabase, fiscalYear: FiscalYear, counterparty: Counterparty
  ) {
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
    let counterparty = Counterparty(
      metadata: EntityMetadata(createdAt: now),
      code: "C001",
      displayName: "株式会社サンプル",
      roles: [.customer, .vendor],
      postalCode: "100-0001",
      address: "東京都千代田区千代田1-1",
      invoiceRegistrationStatus: .qualified,
      invoiceRegistrationNumber: "T1234567890123"
    )
    try database.saveCounterparty(counterparty, at: now)
    return (database, fiscalYear, counterparty)
  }

  private func makeInvoice(
    context: (database: BlueprintDatabase, fiscalYear: FiscalYear, counterparty: Counterparty),
    number: String
  ) throws -> Invoice {
    try Invoice(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: context.fiscalYear.id,
      counterpartyID: context.counterparty.id,
      number: number,
      issueDate: now,
      dueDate: now.addingTimeInterval(86_400 * 30),
      subject: "Webサイト制作費",
      lines: [
        try InvoiceLine(
          description: "企画・制作一式",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      issuerName: "青空デザイン",
      issuerAddress: "東京都渋谷区神南1-1",
      issuerRegistrationStatus: .qualified,
      issuerRegistrationNumber: "T1234567890123"
    )
  }

  private func account(_ code: String, in database: BlueprintDatabase) throws -> Account {
    try XCTUnwrap(database.accounts.fetchAll(includeInactive: false).first { $0.code == code })
  }

  private func receivableAccounts(_ database: BlueprintDatabase) throws
    -> ReceivableSettlementAccounts
  {
    try ReceivableSettlementAccounts(
      receivableAccountID: account("1200", in: database).id,
      bankAccountID: account("1100", in: database).id,
      bankFeeAccountID: account("5500", in: database).id,
      withholdingAccountID: account("2000", in: database).id,
      discountAccountID: account("3100", in: database).id,
      overpaymentAccountID: account("3200", in: database).id
    )
  }
}
