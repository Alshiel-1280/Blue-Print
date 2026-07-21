import BlueprintDomain
import Foundation
import PDFKit
import XCTest

@testable import BlueprintBilling

final class BillingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  func testInvoiceNumberingAndTaxSummaries() throws {
    XCTAssertEqual(
      InvoiceNumbering.next(
        calendarYear: 2026,
        existingNumbers: ["INV-2026-0001", "INV-2025-0040", "INV-2026-0003"]
      ),
      "INV-2026-0004"
    )
    let invoice = try makeInvoice()
    let summaries = try invoice.taxSummaries()
    XCTAssertEqual(summaries.count, 2)
    XCTAssertEqual(
      summaries.first { $0.taxRate == .standard10 }?.taxAmount,
      Money(yen: 10_000)
    )
    XCTAssertEqual(
      summaries.first { $0.taxRate == .reduced8 }?.taxAmount,
      Money(yen: 4_000)
    )
    XCTAssertEqual(try invoice.total(), Money(yen: 164_000))
  }

  func testQualifiedInvoiceRequiredFields() throws {
    var invoice = try makeInvoice()
    invoice.issuerRegistrationNumber = nil
    XCTAssertThrowsError(try invoice.validateForIssue()) { error in
      XCTAssertEqual(error as? BillingError, .missingQualifiedInvoiceField("登録番号"))
    }
  }

  func testPartialAndSplitReceiptsKeepOutstandingBalance() throws {
    var invoice = try makeInvoice()
    invoice.status = .issued
    invoice.journalEntryID = UUID()
    invoice.evidenceID = UUID()
    try invoice.applySettlement(
      InvoiceSettlement(
        receivedAt: now,
        appliedAmount: Money(yen: 60_000),
        cashReceived: Money(yen: 58_000),
        bankFee: Money(yen: 1_000),
        withholdingTax: Money(yen: 1_000)
      ),
      at: now
    )
    XCTAssertEqual(invoice.status, .partiallyPaid)
    XCTAssertEqual(try invoice.outstandingAmount(), Money(yen: 104_000))
    try invoice.applySettlement(
      InvoiceSettlement(
        receivedAt: now,
        appliedAmount: Money(yen: 104_000),
        cashReceived: Money(yen: 104_000)
      ),
      at: now
    )
    XCTAssertEqual(invoice.status, .paid)
    XCTAssertEqual(try invoice.outstandingAmount(), .zero)
  }

  func testVendorWithholdingDefaultsOffAndPartialPaymentKeepsPayable() throws {
    var bill = try VendorBill(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: UUID(),
      vendorID: UUID(),
      referenceNumber: "V-001",
      issueDate: now,
      dueDate: now,
      description: "外注デザイン",
      lines: [
        try InvoiceLine(
          description: "制作費",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      invoiceStatus: .qualified
    )
    XCTAssertFalse(bill.withholdingEnabled)
    XCTAssertEqual(bill.withholdingTax, .zero)
    try bill.confirm(journalEntryID: UUID(), at: now)
    try bill.applyPayment(
      VendorBillPayment(
        paidAt: now,
        appliedAmount: Money(yen: 40_000),
        cashPaid: Money(yen: 35_000),
        withholdingTax: Money(yen: 5_000)
      ),
      at: now
    )
    XCTAssertEqual(bill.status, .partiallyPaid)
    XCTAssertEqual(try bill.outstandingAmount(), Money(yen: 70_000))

    let withholdingBill = try VendorBill(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: UUID(),
      vendorID: UUID(),
      referenceNumber: "V-002",
      issueDate: now,
      dueDate: now,
      description: "源泉対象報酬",
      lines: [
        try InvoiceLine(
          description: "報酬",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      invoiceStatus: .qualified,
      withholdingEnabled: true,
      withholdingTax: Money(yen: 10_210)
    )
    XCTAssertEqual(try withholdingBill.taxSummaries().first?.taxAmount, Money(yen: 10_000))
    XCTAssertEqual(try withholdingBill.grossAmount(), Money(yen: 110_000))
    XCTAssertEqual(try withholdingBill.netPayable(), Money(yen: 99_790))
  }

  func testCorrectionTracksOriginalAndPDFContainsInvoiceFields() throws {
    let invoice = try makeInvoice()
    let correction = try invoice.correction(
      metadata: EntityMetadata(createdAt: now),
      number: "INV-2026-0002",
      lines: invoice.lines,
      reason: "数量訂正"
    )
    XCTAssertEqual(correction.kind, .correction)
    XCTAssertEqual(correction.sourceInvoiceID, invoice.id)
    XCTAssertEqual(correction.reason, "数量訂正")

    let data = try InvoicePDFRenderer.render(
      invoice: invoice,
      recipient: InvoicePDFRecipient(name: "青空商事", postalCode: "150-0001", address: "東京都渋谷区")
    )
    let document = try XCTUnwrap(PDFDocument(data: data))
    let subject =
      document.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
    XCTAssertTrue(subject.contains(invoice.number))
    XCTAssertTrue(subject.contains("T1234567890123"))
    XCTAssertTrue(subject.contains("standard10:100000:10000"))
    XCTAssertTrue(subject.contains("reduced8:50000:4000"))
    XCTAssertTrue(subject.contains("total:164000"))
  }

  func testGenerateVerificationPDFsWhenOutputDirectoryIsConfigured() throws {
    guard let path = ProcessInfo.processInfo.environment["BLUEPRINT_PDF_OUTPUT_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let qualified = try makeInvoice()
    let qualifiedData = try InvoicePDFRenderer.render(
      invoice: qualified,
      recipient: InvoicePDFRecipient(
        name: "株式会社みなと企画",
        postalCode: "100-0001",
        address: "東京都千代田区千代田1-1"
      )
    )
    try qualifiedData.write(to: directory.appendingPathComponent("v0.4-qualified-invoice.pdf"))

    var exempt = qualified
    exempt.number = "INV-2026-0002"
    exempt.issuerRegistrationStatus = .exemptOrUnregistered
    exempt.issuerRegistrationNumber = nil
    let exemptData = try InvoicePDFRenderer.render(
      invoice: exempt,
      recipient: InvoicePDFRecipient(name: "青空商店", address: "東京都世田谷区")
    )
    try exemptData.write(to: directory.appendingPathComponent("v0.4-exempt-invoice.pdf"))
  }

  private func makeInvoice() throws -> Invoice {
    try Invoice(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: UUID(),
      counterpartyID: UUID(),
      number: "INV-2026-0001",
      issueDate: now,
      dueDate: now.addingTimeInterval(30 * 86_400),
      subject: "デザイン業務",
      lines: [
        try InvoiceLine(
          description: "デザイン制作",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        ),
        try InvoiceLine(
          description: "軽減対象資料",
          quantity: 1,
          unitPrice: Money(yen: 50_000),
          taxRate: .reduced8
        ),
      ],
      issuerName: "青空デザイン",
      issuerAddress: "東京都渋谷区",
      issuerRegistrationStatus: .qualified,
      issuerRegistrationNumber: "T1234567890123"
    )
  }
}
