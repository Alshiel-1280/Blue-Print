import BlueprintDocuments
import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintImports

final class ImportsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_785_000_000)

  func testCSVDetectionQuotedFieldsAndPartialErrorIsolation() throws {
    let csv = "日付,金額,摘要,ID\n2026/07/21,12480,\"成城石井, 渋谷店\",A1\n不正,abc,隔離,A2\n"
    let data = Data(csv.utf8)
    let detection = try CSVImporter.detect(data)
    XCTAssertEqual(detection.encoding, .utf8)
    XCTAssertEqual(detection.delimiter, .comma)
    XCTAssertEqual(detection.previewRows[1][2], "成城石井, 渋谷店")
    let profile = ImportProfile(
      name: "テスト銀行",
      sourceKind: .bankCSV,
      encoding: detection.encoding,
      delimiter: detection.delimiter,
      hasHeader: true,
      mapping: ImportColumnMapping(
        dateColumn: 0,
        amountColumn: 1,
        descriptionColumn: 2,
        externalIDColumn: 3
      ),
      updatedAt: now
    )
    let batch = try CSVImporter.makeBatch(
      data: data,
      filename: "bank.csv",
      profile: profile,
      existing: [],
      importedAt: now
    )
    XCTAssertEqual(batch.transactions.count, 1)
    XCTAssertEqual(batch.errors.count, 1)
    XCTAssertEqual(batch.state, .partiallyFailed)
  }

  func testDuplicateKeyUsesExternalIDDateAmountAndDescription() throws {
    let profile = ImportProfile(
      name: "カード",
      sourceKind: .cardCSV,
      encoding: .utf8,
      delimiter: .comma,
      hasHeader: false,
      mapping: ImportColumnMapping(
        dateColumn: 0,
        amountColumn: 1,
        descriptionColumn: 2,
        externalIDColumn: 3
      ),
      updatedAt: now
    )
    let prior = ImportedTransaction(
      batchID: UUID(),
      rowNumber: 1,
      transactionDate: date("2026/07/21"),
      amount: Money(yen: 3_980),
      description: "Amazon.co.jp",
      externalID: "X1"
    )
    let batch = try CSVImporter.makeBatch(
      data: Data("2026/07/21,3980,Amazon.co.jp,X1\n".utf8),
      filename: "card.csv",
      profile: profile,
      existing: [prior],
      importedAt: now
    )
    XCTAssertEqual(batch.transactions.first?.duplicateOfID, prior.id)
    XCTAssertEqual(batch.transactions.first?.state, .needsReview)
  }

  func testQualifiedAndUnregisteredTaxTreatmentsRemainSeparate() {
    let date = date("2026/07/21")
    let qualified = TransitionalTaxRuleResolver.resolve(
      selection: .standard10Qualified,
      transactionDate: date,
      roundingUnit: .line
    )
    let unregistered = TransitionalTaxRuleResolver.resolve(
      selection: .standard10Unregistered,
      transactionDate: date,
      roundingUnit: .voucher
    )
    XCTAssertEqual(qualified.selection.taxRate, .standard10)
    XCTAssertEqual(unregistered.selection.taxRate, .standard10)
    XCTAssertEqual(qualified.selection.invoiceStatus, .qualified)
    XCTAssertEqual(unregistered.selection.invoiceStatus, .exemptOrUnregistered)
    XCTAssertEqual(qualified.deductibleBasisPoints, 10_000)
    XCTAssertEqual(unregistered.deductibleBasisPoints, 8_000)
    XCTAssertEqual(unregistered.roundingUnit, .voucher)
  }

  func testQualifiedAndUnregisteredAmountsAggregateIntoSeparateBuckets() throws {
    let fiscalYearID = UUID()
    let expenseAccountID = UUID()
    let paymentAccountID = UUID()
    let qualified = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      transactionDate: now,
      description: "適格",
      status: .posted,
      lines: [
        try JournalLine(
          accountID: expenseAccountID,
          side: .debit,
          amount: Money(yen: 10_000),
          taxRate: .standard10,
          invoiceStatus: .qualified,
          deductibleBasisPoints: 10_000
        ),
        try JournalLine(
          accountID: paymentAccountID,
          side: .credit,
          amount: Money(yen: 10_000)
        ),
      ]
    )
    let unregistered = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYearID,
      transactionDate: now,
      description: "未登録",
      status: .posted,
      lines: [
        try JournalLine(
          accountID: expenseAccountID,
          side: .debit,
          amount: Money(yen: 8_000),
          taxRate: .standard10,
          invoiceStatus: .exemptOrUnregistered,
          deductibleBasisPoints: 8_000
        ),
        try JournalLine(
          accountID: paymentAccountID,
          side: .credit,
          amount: Money(yen: 8_000)
        ),
      ]
    )

    let balances = try AccountingReports.taxClassificationBalances(
      entries: [qualified, unregistered]
    )
    XCTAssertEqual(balances.count, 2)
    XCTAssertEqual(
      balances.first { $0.invoiceStatus == .qualified }?.taxableAmount,
      Money(yen: 10_000)
    )
    XCTAssertEqual(
      balances.first { $0.invoiceStatus == .exemptOrUnregistered }?.taxableAmount,
      Money(yen: 8_000)
    )
  }

  func testImportBatchCancelsOnlyBeforePosting() {
    let batchID = UUID()
    var batch = ImportBatch(
      id: batchID,
      profileID: nil,
      sourceFilename: "bank.csv",
      importedAt: now,
      state: .imported,
      transactions: [
        ImportedTransaction(
          batchID: batchID,
          rowNumber: 1,
          transactionDate: now,
          amount: Money(yen: 100),
          description: "test"
        )
      ],
      errors: []
    )
    batch.cancelUnposted()
    XCTAssertEqual(batch.state, .cancelled)
    XCTAssertEqual(batch.transactions.first?.state, .excluded)
  }

  private func date(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.date(from: value)!
  }
}
