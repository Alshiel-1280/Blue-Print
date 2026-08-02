import BlueprintBilling
import BlueprintDocuments
import BlueprintDomain
import BlueprintETax
import BlueprintImports
import BlueprintTax
import BlueprintTransfer
import Foundation
import XCTest

@testable import BlueprintPersistence

final class V2ArchitectureTests: XCTestCase {
  private var base: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BluePrintV2Architecture-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let base { try? FileManager.default.removeItem(at: base) }
  }

  func testV2CreatesSeparateSchemaOneWithoutTouchingV1Root() async throws {
    let legacyRoot = base.appendingPathComponent("BluePrint", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let sentinel = legacyRoot.appendingPathComponent("v1-sentinel")
    try Data("must remain unchanged".utf8).write(to: sentinel)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)

    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)

    let version = try await database.userVersion()
    XCTAssertEqual(version, 1)
    XCTAssertEqual(layout.root.lastPathComponent, "BluePrint-v2")
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "must remain unchanged")
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: sentinel.path)[.modificationDate]
        as? Date,
      originalAttributes[.modificationDate] as? Date
    )

    let tableNames = try await database.tableNames()
    XCTAssertTrue(tableNames.contains("journal_entries"))
    XCTAssertTrue(tableNames.contains("invoice_items"))
    XCTAssertTrue(tableNames.contains("jobs"))
    for table in tableNames {
      let columns = try await database.columns(in: table)
      XCTAssertFalse(columns.contains("payload_json"), table)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: layout.generationMarkerURL.path)
    )
  }

  func testPersistentJobsAreIdempotent() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2025, month: 4, day: 1)
      )
    )
    let first = JobRecord(
      idempotencyKey: "ocr:sha256:abc",
      kind: .ocr,
      createdAt: now,
      updatedAt: now
    )
    let duplicate = JobRecord(
      idempotencyKey: first.idempotencyKey,
      kind: .ocr,
      createdAt: now.addingTimeInterval(1),
      updatedAt: now.addingTimeInterval(1)
    )

    try await database.enqueue(first)
    try await database.enqueue(duplicate)

    let jobs = try await database.jobs()
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(jobs.first?.id, first.id)
    XCTAssertEqual(jobs.first?.state, .queued)
  }

  func testPersistentJobProgressAndResumeStateSurviveReload() async throws {
    let root = base.appendingPathComponent("v2-jobs-progress")
    let database = try V2Database(layout: V2StorageLayout(root: root))
    let now = Date(timeIntervalSince1970: 1_735_689_600)
    let job = JobRecord(
      idempotencyKey: "ocr:evidence-1",
      kind: .ocr,
      createdAt: now,
      updatedAt: now
    )
    try await database.enqueue(job)
    try await database.updateJob(
      id: job.id,
      state: BackgroundJobState.running,
      progressBasisPoints: 4_200,
      checkpoint: "page:3",
      at: now.addingTimeInterval(1)
    )

    let reopened = try V2Database(layout: V2StorageLayout(root: root))
    let resumed = try await reopened.resumableJobs()
    XCTAssertEqual(resumed.count, 1)
    XCTAssertEqual(resumed[0].state, BackgroundJobState.running)
    XCTAssertEqual(resumed[0].progressBasisPoints, 4_200)
    XCTAssertEqual(resumed[0].checkpoint, "page:3")

    try await reopened.updateJob(
      id: job.id,
      state: BackgroundJobState.succeeded,
      progressBasisPoints: 10_000,
      checkpoint: "complete",
      at: now.addingTimeInterval(2)
    )
    let remaining = try await reopened.resumableJobs()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testXTXGenerationIsDurableAndIdempotent() async throws {
    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2025, month: 7, day: 1))
    )
    let tax = try OfficialRulePackages.store.taxRule(for: 2025)
    let form = try OfficialRulePackages.store.formRule(for: 2025)
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2025,
      taxRuleSetID: tax.id,
      formRuleSetID: form.id
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      postalAddress: "東京都千代田区千代田1-1",
      taxAddress: "東京都千代田区千代田1-1",
      taxOffice: "麹町税務署",
      taxOfficeCode: "01101",
      eTaxUserID: "1234567890123456",
      bookkeepingStyle: .doubleEntry
    )
    try await database.createInitialSetup(
      profile: profile,
      fiscalYear: fiscalYear,
      at: now
    )
    let accounts = try await database.accounts()
    let cash = try XCTUnwrap(accounts.first { $0.code == "1000" })
    let sales = try XCTUnwrap(accounts.first { $0.code == "4000" })
    let entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: now,
      description: "制作売上",
      lines: [
        try JournalLine(
          accountID: cash.id,
          side: .debit,
          amount: Money(yen: 110_000),
          taxRate: .standard10,
          invoiceStatus: .qualified
        ),
        try JournalLine(
          accountID: sales.id,
          side: .credit,
          amount: Money(yen: 110_000),
          taxRate: .standard10,
          invoiceStatus: .qualified
        ),
      ]
    )
    try await database.saveJournalDraft(entry)
    try await database.postJournal(id: entry.id, fiscalYear: fiscalYear, at: now)

    let service = V2XTXService()
    let first = try await service.generate(
      profile: profile,
      fiscalYear: fiscalYear,
      accounts: accounts,
      journalEntries: try await database.journalEntries(fiscalYearID: fiscalYear.id),
      ruleStore: OfficialRulePackages.store,
      database: database,
      at: now
    )
    let second = try await service.generate(
      profile: profile,
      fiscalYear: fiscalYear,
      accounts: accounts,
      journalEntries: try await database.journalEntries(fiscalYearID: fiscalYear.id),
      ruleStore: OfficialRulePackages.store,
      database: database,
      at: now.addingTimeInterval(60)
    )

    XCTAssertEqual(first.package.hash, second.package.hash)
    XCTAssertEqual(first.durableURL, second.durableURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.durableURL.path))
    XCTAssertTrue(String(decoding: first.package.data, as: UTF8.self).contains("<RKO0010"))
    let jobs = try await database.jobs().filter { $0.kind == .xtxGeneration }
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(jobs.first?.state, .succeeded)
    XCTAssertTrue(jobs.first?.checkpoint?.hasPrefix("XTX/") == true)

    try FileManager.default.removeItem(at: first.durableURL)
    let repaired = try await service.generate(
      profile: profile,
      fiscalYear: fiscalYear,
      accounts: accounts,
      journalEntries: try await database.journalEntries(fiscalYearID: fiscalYear.id),
      ruleStore: OfficialRulePackages.store,
      database: database,
      at: now.addingTimeInterval(120)
    )
    XCTAssertEqual(repaired.package.hash, first.package.hash)
    XCTAssertEqual(repaired.durableURL, first.durableURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.durableURL.path))
    let repairedJobs = try await database.jobs().filter { $0.kind == .xtxGeneration }
    XCTAssertEqual(repairedJobs.count, 1)
  }

  func testXTXValidationFailureIsPersistedAndUnsupportedYearDoesNotEnqueue() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = Date(timeIntervalSince1970: 1_751_328_000)
    let tax = try OfficialRulePackages.store.taxRule(for: 2025)
    let form = try OfficialRulePackages.store.formRule(for: 2025)
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2025,
      taxRuleSetID: tax.id,
      formRuleSetID: form.id
    )
    let incompleteProfile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "未入力 太郎",
      tradeName: "未入力商店",
      bookkeepingStyle: .doubleEntry
    )
    try await database.createInitialSetup(
      profile: incompleteProfile,
      fiscalYear: fiscalYear,
      at: now
    )

    do {
      _ = try await V2XTXService().generate(
        profile: incompleteProfile,
        fiscalYear: fiscalYear,
        accounts: try await database.accounts(),
        journalEntries: [],
        ruleStore: OfficialRulePackages.store,
        database: database,
        at: now
      )
      XCTFail("Incomplete filing identity must fail XTX validation")
    } catch let error as V2XTXGenerationError {
      guard case .validationFailed(let messages) = error else {
        return XCTFail("Unexpected XTX error: \(error)")
      }
      XCTAssertFalse(messages.isEmpty)
    }
    let failedJobs = try await database.jobs().filter { $0.kind == .xtxGeneration }
    XCTAssertEqual(failedJobs.count, 1)
    XCTAssertEqual(failedJobs.first?.state, .failed)
    XCTAssertFalse(failedJobs.first?.failureReason?.isEmpty ?? true)

    let unsupportedYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: try OfficialRulePackages.store.taxRule(for: 2026).id,
      formRuleSetID: "form-2026-unavailable"
    )
    do {
      _ = try await V2XTXService().generate(
        profile: incompleteProfile,
        fiscalYear: unsupportedYear,
        accounts: try await database.accounts(),
        journalEntries: [],
        ruleStore: OfficialRulePackages.store,
        database: database,
        at: now
      )
      XCTFail("Unsupported annual XTX rules must be rejected")
    } catch let error as V2XTXGenerationError {
      XCTAssertEqual(error, .unsupportedYear(2026))
    }
    let allXTXJobs = try await database.jobs().filter { $0.kind == .xtxGeneration }
    XCTAssertEqual(allXTXJobs.count, 1)
  }

  func testRepairRequiresPreviewAndCompletedBackupBeforeRequeue() async throws {
    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    try await database.enqueue(
      JobRecord(
        idempotencyKey: "import:interrupted",
        kind: .dataImport,
        state: .running,
        progressBasisPoints: 4_000,
        checkpoint: "row:40",
        createdAt: now,
        updatedAt: now
      )
    )
    let report = try await database.diagnose(createdAt: now)
    let finding = try XCTUnwrap(
      report.findings.first { $0.code == "jobs.interrupted" }
    )
    XCTAssertEqual(finding.affectedRecordCount, 1)
    XCTAssertEqual(finding.repairKind, "requeue-interrupted-jobs")

    let backupURL = layout.backupsDirectory.appendingPathComponent("before-repair.backup")
    let plan = await database.makeRepairPlan(
      from: report,
      backupURL: backupURL,
      createdAt: now
    )
    XCTAssertEqual(plan.state, .previewed)
    XCTAssertEqual(plan.changes.first?.affectedRecordCount, 1)
    do {
      _ = try await database.apply(plan, at: now)
      XCTFail("Repair must require a completed backup")
    } catch {
      XCTAssertEqual(error as? V2RepairError, .backupNotFound)
    }

    try Data("verified backup".utf8).write(to: backupURL)
    let applied = try await database.apply(plan, at: now.addingTimeInterval(1))
    XCTAssertEqual(applied.state, .applied)
    let jobs = try await database.jobs()
    XCTAssertEqual(jobs.first?.state, .queued)
    XCTAssertEqual(jobs.first?.checkpoint, "row:40")
  }

  func testV2BackupRoundTripRejectsV1Family() async throws {
    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)
    let evidence = layout.evidenceOriginalsDirectory.appendingPathComponent("receipt.txt")
    try Data("original evidence".utf8).write(to: evidence)
    let service = V2BackupService()
    let backup = try await service.makeBackup(
      database: database,
      passphrase: "v2 passphrase",
      createdAt: Date(timeIntervalSince1970: 1_767_225_600)
    )

    XCTAssertThrowsError(
      try service.openBackup(backup, passphrase: "wrong")
    ) { error in
      XCTAssertEqual(error as? V2BackupError, .authenticationFailed)
    }
    let envelope = try JSONDecoder().decode(BackupEnvelopeV2.self, from: backup)
    XCTAssertEqual(Data(base64Encoded: envelope.kdf.saltBase64)?.count, 16)
    var sealed = try XCTUnwrap(Data(base64Encoded: envelope.sealedDataBase64))
    sealed[sealed.startIndex] ^= 0x01
    let tamperedEnvelope = BackupEnvelopeV2(
      kdf: envelope.kdf,
      sealedDataBase64: sealed.base64EncodedString()
    )
    XCTAssertThrowsError(
      try service.openBackup(
        try JSONEncoder().encode(tamperedEnvelope),
        passphrase: "v2 passphrase"
      )
    ) { error in
      XCTAssertEqual(error as? V2BackupError, .authenticationFailed)
    }
    var excessiveKDF = envelope.kdf
    excessiveKDF.memoryKiB = 1_048_576
    let excessiveEnvelope = BackupEnvelopeV2(
      kdf: excessiveKDF,
      sealedDataBase64: envelope.sealedDataBase64
    )
    XCTAssertThrowsError(
      try service.openBackup(
        try JSONEncoder().encode(excessiveEnvelope),
        passphrase: "v2 passphrase"
      )
    ) { error in
      XCTAssertEqual(error as? V2BackupError, .invalidKeyDerivationParameters)
    }
    XCTAssertThrowsError(
      try service.openBackup(Data("{broken".utf8), passphrase: "v2 passphrase")
    ) { error in
      XCTAssertEqual(error as? V2BackupError, .invalidEnvelope)
    }
    let payload = try service.openBackup(backup, passphrase: "v2 passphrase")
    XCTAssertEqual(payload.storageGeneration, 2)
    XCTAssertEqual(payload.databaseSchemaVersion, 1)
    XCTAssertEqual(payload.evidenceFiles.map(\.relativePath), ["Evidence/Originals/receipt.txt"])

    let restoredBase = base.appendingPathComponent("Restored", isDirectory: true)
    try FileManager.default.createDirectory(at: restoredBase, withIntermediateDirectories: true)
    let restoredLayout = V2StorageLayout(applicationSupportBase: restoredBase)
    try service.restore(payload, to: restoredLayout)
    let restored = try V2Database(layout: restoredLayout)
    let restoredVersion = try await restored.userVersion()
    XCTAssertEqual(restoredVersion, 1)
    XCTAssertEqual(
      try String(
        contentsOf: restoredLayout.evidenceOriginalsDirectory
          .appendingPathComponent("receipt.txt"),
        encoding: .utf8
      ),
      "original evidence"
    )

    let v1Envelope = BackupEnvelopeV9(
      kdf: Argon2idParameters(
        memoryKiB: 65_536,
        iterations: 3,
        parallelism: 1,
        outputBytes: 32,
        saltBase64: Data(repeating: 0, count: 16).base64EncodedString()
      ),
      sealedDataBase64: Data(repeating: 0, count: 32).base64EncodedString()
    )
    XCTAssertThrowsError(
      try service.openBackup(try JSONEncoder().encode(v1Envelope), passphrase: "v2 passphrase")
    ) { error in
      XCTAssertEqual(error as? V2BackupError, .invalidEnvelope)
    }
  }

  func testV2NormalizedCoreRoundTripsProfileAccountsAndPostedJournal() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2025, month: 4, day: 1)
      )
    )
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2025,
      taxRuleSetID: "tax-2025.1",
      formRuleSetID: "form-2025.1"
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      postalAddress: "東京都",
      taxOffice: "麹町税務署",
      bookkeepingStyle: .doubleEntry,
      consumptionTaxStatus: .generalTaxation,
      invoiceRegistrationStatus: .qualified,
      invoiceRegistrationNumber: "T1234567890123",
      taxAccountingMethod: .taxInclusive,
      roundingRule: .down
    )
    try await database.createInitialSetup(
      profile: profile,
      fiscalYear: fiscalYear,
      at: now
    )
    let accounts = try await database.accounts()
    let cash = try XCTUnwrap(accounts.first { $0.code == "1000" })
    let sales = try XCTUnwrap(accounts.first { $0.code == "4000" })
    let entry = JournalEntry(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      transactionDate: now,
      description: "売上",
      lines: [
        try JournalLine(
          accountID: cash.id,
          side: .debit,
          amount: Money(yen: 11_000),
          taxRate: .standard10,
          invoiceStatus: .qualified,
          counterparty: "取引先"
        ),
        try JournalLine(
          accountID: sales.id,
          side: .credit,
          amount: Money(yen: 11_000),
          taxRate: .standard10,
          invoiceStatus: .qualified,
          counterparty: "取引先"
        ),
      ]
    )
    try await database.saveJournalDraft(entry)
    try await database.postJournal(id: entry.id, fiscalYear: fiscalYear, at: now)

    let loadedProfiles = try await database.profiles()
    let restoredProfile = try XCTUnwrap(loadedProfiles.first)
    XCTAssertEqual(restoredProfile.tradeName, "青空デザイン")
    XCTAssertEqual(restoredProfile.invoiceRegistrationNumber, "T1234567890123")
    let loadedEntries = try await database.journalEntries(fiscalYearID: fiscalYear.id)
    let restoredEntry = try XCTUnwrap(loadedEntries.first)
    XCTAssertEqual(restoredEntry.status, .posted)
    XCTAssertEqual(restoredEntry.lines.map(\.amount.yen), [11_000, 11_000])
    XCTAssertEqual(restoredEntry.lines.first?.invoiceStatus, .qualified)
    XCTAssertEqual(restoredEntry.lines.first?.counterparty, "取引先")
  }

  func testEvidenceImportKeepsOriginalAndPersistsOCRCandidates() async throws {
    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)
    let source = base.appendingPathComponent("receipt.jpg")
    let original = Data("immutable-original".utf8)
    try original.write(to: source)
    let service = V2EvidenceService(
      recognizer: StubOCRRecognizer(
        lines: [
          RecognizedTextLine(text: "青空商店", confidence: 0.98),
          RecognizedTextLine(text: "2026/07/29", confidence: 0.95),
          RecognizedTextLine(text: "合計 ¥1,100", confidence: 0.93),
        ]
      )
    )

    let result = try await service.importAndRecognize(
      sourceURL: source,
      origin: .electronicTransaction,
      fiscalYearID: nil,
      database: database,
      at: Date(timeIntervalSince1970: 1_775_000_000)
    )
    let storedURL = layout.root.appendingPathComponent(result.document.originalRelativePath)
    XCTAssertEqual(try Data(contentsOf: storedURL), original)
    XCTAssertEqual(result.document.state, .needsReview)
    XCTAssertTrue(result.candidates.contains { $0.field == .transactionDate })
    XCTAssertTrue(result.candidates.contains { $0.field == .amount })
    let persistedCandidates = try await database.ocrCandidates(evidenceID: result.document.id)
    let persistedJobs = try await database.jobs()
    XCTAssertEqual(
      persistedCandidates.sorted { $0.id.uuidString < $1.id.uuidString },
      result.candidates.sorted { $0.id.uuidString < $1.id.uuidString }
    )
    XCTAssertEqual(persistedJobs.first?.state, .succeeded)

    do {
      _ = try await service.importAndRecognize(
        sourceURL: source,
        origin: .electronicTransaction,
        fiscalYearID: nil,
        database: database
      )
      XCTFail("Exact duplicate must be rejected")
    } catch {
      guard case V2EvidenceServiceError.duplicate = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRecurringCandidateRequiresExplicitConfirmation() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 7, day: 29)
      )
    )
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "tax-2026",
      formRuleSetID: "form-2026-unavailable"
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      bookkeepingStyle: .doubleEntry,
      consumptionTaxStatus: .generalTaxation,
      invoiceRegistrationStatus: .qualified,
      taxAccountingMethod: .taxExclusive,
      roundingRule: .down
    )
    try await database.createInitialSetup(profile: profile, fiscalYear: year, at: now)
    let accounts = try await database.accounts()
    let communications = try XCTUnwrap(accounts.first { $0.code == "5300" })
    let bank = try XCTUnwrap(accounts.first { $0.code == "1100" })
    let template = JournalTemplateV2(
      name: "通信費",
      defaultDescription: "月額回線",
      debitAccountID: communications.id,
      creditAccountID: bank.id,
      taxRate: .standard10,
      invoiceStatus: .qualified,
      createdAt: now,
      updatedAt: now
    )
    try await database.saveJournalTemplate(template)
    try await database.saveRecurringJournal(
      RecurringJournalV2(
        templateID: template.id,
        frequency: .monthly,
        dayOfMonth: 29,
        amountYen: 5_500,
        nextRunAt: now,
        createdAt: now,
        updatedAt: now
      )
    )

    _ = try await GenerateRecurringCandidatesUseCase(repository: database).execute(dueAt: now)
    let pending = try await database.journalCandidates(state: .pending)
    let entriesBeforeConfirmation = try await database.journalEntries(fiscalYearID: year.id)
    XCTAssertEqual(pending.count, 1)
    XCTAssertTrue(entriesBeforeConfirmation.isEmpty)

    _ = try await ConfirmJournalCandidateUseCase(repository: database).execute(
      candidate: try XCTUnwrap(pending.first),
      fiscalYear: year,
      at: now
    )
    let entriesAfterConfirmation = try await database.journalEntries(fiscalYearID: year.id)
    let remainingPending = try await database.journalCandidates(state: .pending)
    let confirmed = try await database.journalCandidates(state: .confirmed)
    XCTAssertEqual(entriesAfterConfirmation.count, 1)
    XCTAssertTrue(remainingPending.isEmpty)
    XCTAssertEqual(confirmed.count, 1)
  }

  func testStagedRestoreSwapsOnlyV2AndPreservesPreviousGeneration() async throws {
    let currentBase = base.appendingPathComponent("current", isDirectory: true)
    let sourceBase = base.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: currentBase, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceBase, withIntermediateDirectories: true)
    let v1Root = currentBase.appendingPathComponent("BluePrint", isDirectory: true)
    try FileManager.default.createDirectory(at: v1Root, withIntermediateDirectories: true)
    let sentinel = v1Root.appendingPathComponent("sentinel")
    try Data("v1-untouched".utf8).write(to: sentinel)

    let currentLayout = V2StorageLayout(applicationSupportBase: currentBase)
    let current = try V2Database(layout: currentLayout)
    let now = Date(timeIntervalSince1970: 1_775_000_000)
    try await current.enqueue(
      JobRecord(
        idempotencyKey: "current",
        kind: .matching,
        createdAt: now,
        updatedAt: now
      )
    )
    let source = try V2Database(layout: V2StorageLayout(applicationSupportBase: sourceBase))
    try await source.enqueue(
      JobRecord(
        idempotencyKey: "restored",
        kind: .ocr,
        createdAt: now,
        updatedAt: now
      )
    )
    let service = V2BackupService()
    let backup = try await service.makeBackup(database: source, passphrase: "restore passphrase")
    let payload = try service.openBackup(backup, passphrase: "restore passphrase")
    let coordinator = V2RestoreCoordinator()
    try coordinator.stage(payload: payload, for: currentLayout)
    let preserved = try XCTUnwrap(
      coordinator.applyPendingRestoreIfNeeded(to: currentLayout)
    )

    let restored = try V2Database(layout: currentLayout)
    let restoredJobs = try await restored.jobs()
    XCTAssertEqual(restoredJobs.map(\.idempotencyKey), ["restored"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "v1-untouched")
  }

  func testCounterpartyInvoiceAndSettlementAreNormalizedAndAudited() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 6, day: 1)
      )
    )
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2026,
      taxRuleSetID: "tax-2026",
      formRuleSetID: "form-2026-unavailable"
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      bookkeepingStyle: .doubleEntry,
      consumptionTaxStatus: .generalTaxation,
      invoiceRegistrationStatus: .qualified,
      taxAccountingMethod: .taxExclusive,
      roundingRule: .down
    )
    try await database.createInitialSetup(profile: profile, fiscalYear: year, at: now)
    let counterparty = Counterparty(
      metadata: EntityMetadata(createdAt: now),
      code: "C001",
      displayName: "取引先A",
      roles: [.customer],
      invoiceRegistrationStatus: .qualified,
      invoiceRegistrationNumber: "T1234567890123"
    )
    try await database.saveCounterparty(counterparty)
    var invoice = try Invoice(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      counterpartyID: counterparty.id,
      number: "INV-001",
      issueDate: now,
      dueDate: now.addingTimeInterval(30 * 86_400),
      subject: "制作費",
      status: .issued,
      lines: [
        try InvoiceLine(
          description: "制作費",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      issuerName: "青空デザイン",
      issuerRegistrationStatus: .exemptOrUnregistered
    )
    try invoice.applySettlement(
      InvoiceSettlement(
        receivedAt: now.addingTimeInterval(10 * 86_400),
        appliedAmount: Money(yen: 50_000),
        cashReceived: Money(yen: 50_000)
      ),
      at: now.addingTimeInterval(10 * 86_400)
    )
    try await database.saveInvoice(invoice)

    let restoredParties = try await database.counterparties()
    let restoredInvoices = try await database.invoices(fiscalYearID: year.id)
    let audit = try await database.auditEvents()
    XCTAssertEqual(restoredParties, [counterparty])
    XCTAssertEqual(restoredInvoices, [invoice])
    XCTAssertTrue(
      audit.contains {
        $0.targetType == "Invoice" && $0.targetID == invoice.id.uuidString.lowercased()
      })
    for table in [
      "counterparties", "counterparty_roles", "invoices", "invoice_items", "settlements",
    ] {
      let columns = try await database.columns(in: table)
      XCTAssertFalse(columns.contains("payload_json"))
    }
  }

  func testV2InvoiceIssueAndFullSettlementAreAtomicAndIdempotent() async throws {
    let layout = V2StorageLayout(applicationSupportBase: base)
    let database = try V2Database(layout: layout)
    let now = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2025, month: 8, day: 1)
      )
    )
    let year = try FiscalYear(
      metadata: EntityMetadata(createdAt: now),
      calendarYear: 2025,
      taxRuleSetID: "tax-2025",
      formRuleSetID: "form-2025"
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      ownerName: "青空 花子",
      tradeName: "青空デザイン",
      bookkeepingStyle: .doubleEntry,
      invoiceRegistrationStatus: .exemptOrUnregistered
    )
    try await database.createInitialSetup(profile: profile, fiscalYear: year, at: now)
    let customer = Counterparty(
      metadata: EntityMetadata(createdAt: now),
      code: "C001",
      displayName: "取引先A",
      roles: [.customer]
    )
    try await database.saveCounterparty(customer)
    let accounts = try await database.accounts()
    func account(_ code: String) throws -> UUID {
      try XCTUnwrap(accounts.first { $0.code == code }).id
    }
    let draft = try Invoice(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: year.id,
      counterpartyID: customer.id,
      number: "INV-2025-0001",
      issueDate: now,
      dueDate: now.addingTimeInterval(30 * 86_400),
      subject: "デザイン制作",
      lines: [
        try InvoiceLine(
          description: "デザイン制作",
          quantity: 1,
          unitPrice: Money(yen: 100_000),
          taxRate: .standard10
        )
      ],
      issuerName: profile.tradeName,
      issuerRegistrationStatus: .exemptOrUnregistered
    )
    let issued = try await database.issueInvoice(
      draft,
      accounts: InvoiceIssueAccounts(
        receivableAccountID: try account("1200"),
        revenueAccountID: try account("4000")
      ),
      at: now
    )
    let issuedAgain = try await database.issueInvoice(
      draft,
      accounts: InvoiceIssueAccounts(
        receivableAccountID: try account("1200"),
        revenueAccountID: try account("4000")
      ),
      at: now.addingTimeInterval(1)
    )
    XCTAssertEqual(issuedAgain.id, issued.id)
    XCTAssertEqual(issuedAgain.journalEntryID, issued.journalEntryID)
    XCTAssertEqual(issued.status, .issued)
    let evidenceID = try XCTUnwrap(issued.evidenceID)
    let storedEvidence = try await database.evidenceDocument(id: evidenceID)
    let evidence = try XCTUnwrap(storedEvidence)
    let pdfURL = layout.root.appendingPathComponent(evidence.originalRelativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
    XCTAssertTrue(try Data(contentsOf: pdfURL).starts(with: Data("%PDF".utf8)))

    let outstanding = try issued.outstandingAmount()
    let settlement = try InvoiceSettlement(
      receivedAt: now.addingTimeInterval(10 * 86_400),
      appliedAmount: outstanding,
      cashReceived: outstanding
    )
    let paid = try await database.settleInvoice(
      invoiceID: issued.id,
      settlement: settlement,
      accounts: ReceivableSettlementAccounts(
        receivableAccountID: try account("1200"),
        bankAccountID: try account("1100"),
        bankFeeAccountID: try account("5500"),
        withholdingAccountID: try account("2000"),
        discountAccountID: try account("3100"),
        overpaymentAccountID: try account("3200")
      ),
      at: settlement.receivedAt
    )
    XCTAssertEqual(paid.status, .paid)
    XCTAssertEqual(try paid.outstandingAmount(), .zero)
    XCTAssertEqual(paid.settlements.count, 1)
    XCTAssertNotNil(paid.settlements.first?.journalEntryID)
    let journals = try await database.journalEntries(fiscalYearID: year.id)
    XCTAssertEqual(journals.count, 2)
    XCTAssertTrue(journals.allSatisfy { $0.status == .posted })
  }

  func testJournalRuleGeneratesPendingCandidateButNeverPostsAutomatically() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = Date(timeIntervalSince1970: 1_775_000_000)
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let communications = try XCTUnwrap(accounts.first { $0.code == "5300" })
    let bank = try XCTUnwrap(accounts.first { $0.code == "1100" })
    try await database.saveAccount(communications)
    try await database.saveAccount(bank)
    try await database.saveJournalRule(
      JournalRuleV2(
        name: "回線",
        descriptionContains: "通信",
        debitAccountID: communications.id,
        creditAccountID: bank.id,
        taxRate: .standard10,
        createdAt: now,
        updatedAt: now
      )
    )
    let source = ImportCandidateV1(
      sourceKind: "bank",
      sourceFingerprint: "sha256:row-1",
      occurredAt: now,
      amountYen: -5_500,
      description: "通信サービス 7月分"
    )
    let candidate = try await GenerateRuleCandidateUseCase(repository: database)
      .execute(importCandidate: source, at: now)
    let pending = try await database.journalCandidates(state: .pending)
    let entries = try await database.journalEntries()
    XCTAssertEqual(candidate?.state, .pending)
    XCTAssertEqual(pending.count, 1)
    XCTAssertTrue(entries.isEmpty)
  }

  func testCSVImportAndEvidenceMatchingArePersistentIdempotentCandidates() async throws {
    let database = try V2Database(
      layout: V2StorageLayout(applicationSupportBase: base)
    )
    let now = Date(timeIntervalSince1970: 1_751_328_000)
    let accounts = StandardChartOfAccounts.accounts(createdAt: now)
    let communications = try XCTUnwrap(accounts.first { $0.code == "5300" })
    let bank = try XCTUnwrap(accounts.first { $0.code == "1100" })
    try await database.saveAccount(communications)
    try await database.saveAccount(bank)
    try await database.saveJournalRule(
      JournalRuleV2(
        name: "通信費",
        descriptionContains: "通信",
        debitAccountID: communications.id,
        creditAccountID: bank.id,
        taxRate: .standard10,
        createdAt: now,
        updatedAt: now
      )
    )
    let evidence = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: String(repeating: "a", count: 64),
      originalRelativePath: "Evidence/Originals/receipt.pdf",
      originalFilename: "receipt.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .electronicTransaction,
      state: .needsReview,
      transactionDate: now,
      amount: Money(yen: 5_500),
      counterparty: "通信サービス"
    )
    try await database.saveEvidence(evidence, fiscalYearID: nil)
    let profile = ImportProfile(
      name: "銀行",
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
    let csv = Data(
      """
      日付,金額,摘要,ID
      2025/07/01,-5500,通信サービス 7月分,row-1

      """.utf8
    )
    let service = V2ImportMatchingService()
    let imported = try await service.importCSV(
      data: csv,
      filename: "bank.csv",
      profile: profile,
      database: database,
      at: now
    )
    XCTAssertEqual(imported.candidates.count, 1)
    XCTAssertEqual(imported.job.state, .succeeded)
    let journalCandidates = try await database.journalCandidates(state: .pending)
    XCTAssertEqual(journalCandidates.count, 1)

    let matched = try await service.generateMatches(database: database, at: now)
    let match = try XCTUnwrap(matched.candidates.first)
    XCTAssertEqual(match.confidenceBasisPoints, 10_000)
    XCTAssertNotNil(match.journalCandidateID)
    try await database.markMatchCandidate(id: match.id, state: .accepted, at: now)
    let acceptedImports = try await database.importCandidates()
    XCTAssertEqual(acceptedImports.first?.state, .matched)

    _ = try await service.importCSV(
      data: csv,
      filename: "bank.csv",
      profile: profile,
      database: database,
      at: now.addingTimeInterval(1)
    )
    let persistedImports = try await database.importCandidates()
    let importJobs = try await database.jobs().filter { $0.kind == .dataImport }
    XCTAssertEqual(persistedImports.count, 1)
    XCTAssertEqual(importJobs.count, 1)
  }
}

private struct StubOCRRecognizer: OCRRecognizing {
  let lines: [RecognizedTextLine]
  func recognize(url: URL) throws -> [RecognizedTextLine] { lines }
}
