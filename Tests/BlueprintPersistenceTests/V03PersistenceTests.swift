import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V03PersistenceTests: XCTestCase {
  private var root: URL!
  private var databaseURL: URL { root.appendingPathComponent("Database/blueprint.sqlite") }
  private var backupDirectory: URL { root.appendingPathComponent("Backups") }
  private let now = Date(timeIntervalSince1970: 1_785_000_000)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BluePrintV03-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testVersion3MigratesToEvidenceSchemaWithBackupAndDataPreserved() throws {
    try SampleDatabaseFactory.makeVersion3Database(at: databaseURL, date: now)
    let database = try BlueprintDatabase(
      databaseURL: databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: backupDirectory)
    )

    XCTAssertEqual(try database.connection.scalarInt("PRAGMA user_version"), 5)
    XCTAssertEqual(try database.profiles.fetchAll().first?.tradeName, "移行テスト事業者")
    XCTAssertEqual(
      try database.connection.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'evidence_documents'"
      ),
      1
    )
    let columns = try database.connection.query("PRAGMA table_info(journal_lines)")
    XCTAssertTrue(columns.contains { $0["name"]?.string == "invoice_status" })
    let backups = try FileManager.default.contentsOfDirectory(
      at: backupDirectory,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(backups.count, 1)
    XCTAssertTrue(backups[0].lastPathComponent.contains("pre-migration-v3-to-v5"))
  }

  func testDuplicateImportAndOCRCorrectionPreserveImmutableOriginal() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let source = root.appendingPathComponent("receipt.txt")
    try Data("原本レシート".utf8).write(to: source)
    let document = try database.importEvidence(
      from: source,
      mimeType: "text/plain",
      origin: .paperScan,
      at: now
    )
    let originalURL = database.evidenceFileStore.originalURL(
      relativePath: document.originalRelativePath
    )
    let before = try database.evidenceFileStore.fingerprint(originalURL)

    XCTAssertThrowsError(
      try database.importEvidence(
        from: source,
        mimeType: "text/plain",
        origin: .paperScan,
        at: now
      )
    ) { error in
      XCTAssertEqual(error as? EvidenceError, .exactDuplicate(existingID: document.id))
    }

    let candidates = try database.processOCR(
      evidenceID: document.id,
      recognizer: FixedRecognizer(),
      at: now.addingTimeInterval(1)
    )
    let amountCandidate = try XCTUnwrap(candidates.first { $0.field == .amount })
    try database.correctOCRCandidate(
      id: amountCandidate.id,
      evidenceID: document.id,
      value: "12480",
      at: now.addingTimeInterval(2)
    )
    let after = try database.evidenceFileStore.fingerprint(originalURL)

    XCTAssertEqual(before.sha256, after.sha256)
    XCTAssertEqual(try database.evidence.search(EvidenceSearch()).count, 1)
    XCTAssertEqual(
      try database.evidence.candidates(evidenceID: document.id)
        .first { $0.id == amountCandidate.id }?.correctedValue,
      "12480"
    )
    XCTAssertEqual(
      try database.auditEvents.fetch(
        targetType: "OCRCandidate",
        targetID: amountCandidate.id.uuidString.lowercased()
      ).count,
      1
    )
  }

  func testEvidenceRequiresExplicitConfirmationThenPostsWithIndependentTaxValues() throws {
    let database = try configuredDatabase()
    let setup = try XCTUnwrap(try database.fiscalYears.fetchAll().first)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let source = root.appendingPathComponent("invoice.pdf")
    try Data("invoice bytes".utf8).write(to: source)
    let document = try database.importEvidence(
      from: source,
      mimeType: "application/pdf",
      origin: .electronicTransaction,
      at: now
    )
    _ = try database.processOCR(
      evidenceID: document.id,
      recognizer: FixedRecognizer(),
      at: now.addingTimeInterval(1)
    )

    XCTAssertTrue(try database.journals.search(JournalSearch(fiscalYearID: setup.id)).isEmpty)
    let entry = try database.confirmEvidenceAndPost(
      evidenceID: document.id,
      fiscalYearID: setup.id,
      expenseAccountID: accounts[0].id,
      paymentAccountID: accounts[8].id,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井",
      description: "会議費",
      taxSelection: .standard10Unregistered,
      roundingUnit: .voucher,
      at: now.addingTimeInterval(2)
    )

    XCTAssertEqual(entry.status, .posted)
    XCTAssertEqual(entry.lines[0].taxRate, .standard10)
    XCTAssertEqual(entry.lines[0].invoiceStatus, .exemptOrUnregistered)
    XCTAssertEqual(entry.lines[0].deductibleBasisPoints, 8_000)
    XCTAssertEqual(entry.lines[0].roundingUnit, .voucher)
    XCTAssertEqual(
      try database.evidence.links(evidenceID: document.id).first?.journalEntryID, entry.id)
    XCTAssertEqual(try database.evidence.fetch(id: document.id)?.state, .posted)
  }

  func testCSVPartialErrorsPersistAndUnpostedBatchCanBeCancelled() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let profile = ImportProfile(
      name: "青空銀行",
      sourceKind: .bankCSV,
      encoding: .utf8,
      delimiter: .comma,
      hasHeader: true,
      mapping: ImportColumnMapping(
        dateColumn: 0,
        amountColumn: 1,
        descriptionColumn: 2,
        externalIDColumn: 3
      ),
      updatedAt: now
    )
    let batch = try database.importCSV(
      data: Data("日付,金額,摘要,ID\n2026/07/21,12480,成城石井,A1\n不正,abc,隔離,A2\n".utf8),
      filename: "bank.csv",
      profile: profile,
      at: now
    )

    XCTAssertEqual(batch.transactions.count, 1)
    XCTAssertEqual(batch.errors.count, 1)
    XCTAssertEqual(try database.imports.batches().first?.state, .partiallyFailed)
    try database.imports.cancelBatch(id: batch.id)
    let cancelled = try XCTUnwrap(try database.imports.batches().first)
    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertEqual(cancelled.transactions.first?.state, .excluded)
  }

  func testLockedFiscalYearRejectsEvidenceAndCSVImports() throws {
    let database = try configuredDatabase()
    let fiscalYear = try XCTUnwrap(try database.fiscalYears.fetchAll().first)
    try database.lockFiscalYear(id: fiscalYear.id, at: now)
    let source = root.appendingPathComponent("locked.png")
    try Data("locked".utf8).write(to: source)

    XCTAssertThrowsError(
      try database.importEvidence(
        from: source,
        mimeType: "image/png",
        origin: .paperScan,
        at: now
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryError, .fiscalYearLocked)
    }
    let profile = ImportProfile(
      name: "ロック年度",
      sourceKind: .bankCSV,
      encoding: .utf8,
      delimiter: .comma,
      hasHeader: false,
      mapping: ImportColumnMapping(dateColumn: 0, amountColumn: 1, descriptionColumn: 2),
      updatedAt: now
    )
    XCTAssertThrowsError(
      try database.importCSV(
        data: Data("2026/07/21,100,ロック\n".utf8),
        filename: "locked.csv",
        profile: profile,
        at: now
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryError, .fiscalYearLocked)
    }
  }

  func testElectronicEvidenceSearchesByDateAmountAndCounterparty() throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    let electronic = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "electronic",
      originalRelativePath: "electronic.pdf",
      originalFilename: "electronic.pdf",
      mimeType: "application/pdf",
      byteCount: 120,
      acquiredAt: now,
      origin: .electronicTransaction,
      state: .needsReview,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井"
    )
    let paper = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "paper",
      originalRelativePath: "paper.pdf",
      originalFilename: "paper.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .paperScan,
      state: .needsReview,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井"
    )
    try database.evidence.save(electronic)
    try database.evidence.save(paper)

    let results = try database.evidence.search(
      EvidenceSearch(
        dateRange: now.addingTimeInterval(-1)...now.addingTimeInterval(1),
        amount: Money(yen: 12_480),
        counterparty: "成城",
        electronicOnly: true
      ))
    XCTAssertEqual(results.map(\.id), [electronic.id])
  }

  func testImportedTransactionSuggestsEvidenceAssociatesAndPostsOnce() throws {
    let database = try configuredDatabase()
    let fiscalYear = try XCTUnwrap(try database.fiscalYears.fetchAll().first)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let document = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "candidate",
      originalRelativePath: "candidate.pdf",
      originalFilename: "candidate.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .electronicTransaction,
      state: .needsReview,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井"
    )
    try database.evidence.save(document)
    let profile = ImportProfile(
      name: "青空銀行",
      sourceKind: .bankCSV,
      encoding: .utf8,
      delimiter: .comma,
      hasHeader: false,
      mapping: ImportColumnMapping(dateColumn: 0, amountColumn: 1, descriptionColumn: 2),
      updatedAt: now
    )
    let batch = try database.importCSV(
      data: Data("2026/07/26,12480,成城石井 渋谷店\n".utf8),
      filename: "bank.csv",
      profile: profile,
      at: now
    )
    let transaction = try XCTUnwrap(batch.transactions.first)

    XCTAssertEqual(
      try database.evidenceCandidates(for: transaction.id).first?.evidenceID, document.id)
    try database.associateEvidence(
      transactionID: transaction.id,
      evidenceID: document.id,
      at: now.addingTimeInterval(1)
    )
    let entry = try database.confirmImportedTransaction(
      transactionID: transaction.id,
      fiscalYearID: fiscalYear.id,
      expenseAccountID: accounts[0].id,
      paymentAccountID: accounts[8].id,
      taxSelection: .standard10Qualified,
      roundingUnit: .line,
      at: now.addingTimeInterval(2)
    )

    XCTAssertEqual(
      try database.evidence.links(evidenceID: document.id).first?.journalEntryID, entry.id)
    XCTAssertThrowsError(
      try database.confirmImportedTransaction(
        transactionID: transaction.id,
        fiscalYearID: fiscalYear.id,
        expenseAccountID: accounts[0].id,
        paymentAccountID: accounts[8].id,
        taxSelection: .standard10Qualified,
        roundingUnit: .line,
        at: now.addingTimeInterval(3)
      )
    )
    let reconciliation = try database.reconcile(
      statementBalance: Money(yen: -12_480),
      bankAccountID: accounts[8].id,
      fiscalYearID: fiscalYear.id
    )
    XCTAssertTrue(reconciliation.isReconciled)
  }

  private func configuredDatabase() throws -> BlueprintDatabase {
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
    return database
  }
}

private struct FixedRecognizer: OCRRecognizing {
  func recognize(url: URL) throws -> [RecognizedTextLine] {
    [
      RecognizedTextLine(text: "成城石井", confidence: 0.96),
      RecognizedTextLine(text: "2026年7月21日", confidence: 0.94),
      RecognizedTextLine(text: "合計 12,408円", confidence: 0.91),
      RecognizedTextLine(text: "T1234567890123 10%", confidence: 0.88),
    ]
  }
}
