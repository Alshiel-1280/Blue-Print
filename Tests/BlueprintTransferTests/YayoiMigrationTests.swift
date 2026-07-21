import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintTransfer

final class YayoiMigrationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  func testSingleAndCompoundJournalsMapAccountsTaxAndInvoiceStatus() throws {
    let rows = [
      row(
        flag: "2000", date: "2025/04/01", debitAccount: "消耗品費",
        debitTax: "課対仕入込10%適格", debitAmount: "1100", creditAccount: "普通預金",
        creditTax: "対象外", creditAmount: "1100", description: "文具", debitSubAccount: "文具店"),
      row(
        flag: "2110", date: "2025/04/02", debitAccount: "消耗品費",
        debitTax: "課対仕入込10%区分80%", debitAmount: "800", creditAccount: "普通預金",
        creditTax: "対象外", creditAmount: "1000", description: "備品等"),
      row(
        flag: "2101", date: "", debitAccount: "通信費", debitTax: "課対仕入込10%適格",
        debitAmount: "200", creditAccount: "", creditTax: "", creditAmount: "0",
        description: ""),
    ]
    let batch = try YayoiCSVImporter.preview(
      data: Data(rows.joined(separator: "\r\n").utf8),
      filename: "yayoi.csv",
      product: .desktopOrOnline,
      availableAccounts: StandardChartOfAccounts.accounts(createdAt: now),
      importedAt: now
    )

    XCTAssertEqual(
      batch.entries.count, 2, "entries=\(batch.entries) quarantine=\(batch.quarantinedRows)")
    guard batch.entries.count == 2 else { return }
    XCTAssertTrue(batch.entries.allSatisfy { $0.isBalanced })
    XCTAssertTrue(batch.quarantinedRows.isEmpty)
    XCTAssertTrue(batch.accountMappings.allSatisfy { $0.targetAccountID != nil })
    XCTAssertEqual(batch.subAccountMappings.first?.sourceSubAccount, "文具店")
    XCTAssertEqual(batch.entries[0].lines[0].tax.rate, .standard10)
    XCTAssertEqual(batch.entries[0].lines[0].tax.invoiceStatus, .qualified)
    XCTAssertEqual(batch.entries[1].lines[0].tax.invoiceStatus, .exemptOrUnregistered)
    XCTAssertEqual(batch.entries[1].lines[0].tax.deductibleBasisPoints, 8_000)
    XCTAssertTrue(batch.accountBalanceComparison.allSatisfy { $0.differenceYen == 0 })
  }

  func testInvalidRowsAreQuarantinedWithoutDiscardingValidRows() throws {
    let rows = [
      row(
        flag: "2000", date: "2025/05/01", debitAccount: "通信費",
        debitTax: "課対仕入込10%適格", debitAmount: "500", creditAccount: "現金",
        creditTax: "対象外", creditAmount: "500", description: "回線"),
      row(
        flag: "9999", date: "2025/05/02", debitAccount: "通信費",
        debitTax: "未知税区分", debitAmount: "400", creditAccount: "現金",
        creditTax: "対象外", creditAmount: "400", description: "隔離"),
    ]
    let batch = try YayoiCSVImporter.preview(
      data: Data(rows.joined(separator: "\n").utf8),
      filename: "partial.csv",
      product: .next,
      availableAccounts: StandardChartOfAccounts.accounts(createdAt: now)
    )

    XCTAssertEqual(batch.entries.count, 1)
    XCTAssertEqual(batch.quarantinedRows.count, 1)
    XCTAssertEqual(batch.state, .partiallyFailed)
  }

  func testPreviewBatchCanBeCancelled() throws {
    var batch = try YayoiCSVImporter.preview(
      data: Data(
        row(
          flag: "2000", date: "2025/06/01", debitAccount: "現金", debitTax: "対象外",
          debitAmount: "100", creditAccount: "売上高", creditTax: "課税売上込10%",
          creditAmount: "100", description: "売上"
        ).utf8),
      filename: "cancel.csv",
      product: .desktopOrOnline,
      availableAccounts: StandardChartOfAccounts.accounts(createdAt: now)
    )
    batch.cancel()
    XCTAssertEqual(batch.state, .cancelled)
  }

  func testNextOpeningBalancesArePreviewedAndBalanced() throws {
    let csv = [
      "2025/01/01,現金,借方,,,120000",
      ",元入金,貸方,,,120000",
    ].joined(separator: "\n")
    let batch = try YayoiCSVImporter.preview(
      data: Data(csv.utf8),
      filename: "opening.csv",
      product: .next,
      availableAccounts: StandardChartOfAccounts.accounts(createdAt: now)
    )

    XCTAssertEqual(batch.entries.count, 1)
    XCTAssertEqual(batch.entries[0].description, "期首残高")
    XCTAssertTrue(batch.entries[0].isBalanced)
    XCTAssertTrue(batch.quarantinedRows.isEmpty)
  }

  private func row(
    flag: String,
    date: String,
    debitAccount: String,
    debitTax: String,
    debitAmount: String,
    creditAccount: String,
    creditTax: String,
    creditAmount: String,
    description: String,
    debitSubAccount: String = ""
  ) -> String {
    var columns = Array(repeating: "", count: 25)
    columns[0] = flag
    columns[3] = date
    columns[4] = debitAccount
    columns[5] = debitSubAccount
    columns[7] = debitTax
    columns[8] = debitAmount
    columns[10] = creditAccount
    columns[13] = creditTax
    columns[14] = creditAmount
    columns[16] = description
    return columns.map { "\"\($0)\"" }.joined(separator: ",")
  }
}
