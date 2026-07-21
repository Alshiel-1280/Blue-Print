import BlueprintAudit
import BlueprintBilling
import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import Foundation

public final class BlueprintDatabase: @unchecked Sendable {
  public let connection: SQLiteConnection
  public let profiles: SQLiteBusinessProfileRepository
  public let fiscalYears: SQLiteFiscalYearRepository
  public let accounts: SQLiteAccountRepository
  public let journals: SQLiteJournalRepository
  public let evidence: SQLiteEvidenceRepository
  public let imports: SQLiteImportRepository
  public let billing: SQLiteBillingRepository
  public let evidenceFileStore: EvidenceFileStore
  public let auditEvents: SQLiteAuditEventRepository

  public init(
    databaseURL: URL,
    backupHook: any MigrationBackupHook = NoopMigrationBackupHook()
  ) throws {
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try DatabaseMigrator().migrate(connection: connection, backupHook: backupHook)
    try connection.enableWriteAheadLogging()
    self.connection = connection
    profiles = SQLiteBusinessProfileRepository(connection: connection)
    fiscalYears = SQLiteFiscalYearRepository(connection: connection)
    accounts = SQLiteAccountRepository(connection: connection)
    journals = SQLiteJournalRepository(connection: connection)
    evidence = SQLiteEvidenceRepository(connection: connection)
    imports = SQLiteImportRepository(connection: connection)
    billing = SQLiteBillingRepository(connection: connection)
    let root = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
    evidenceFileStore = EvidenceFileStore(
      originalsDirectory: root.appendingPathComponent("Evidence/Originals", isDirectory: true),
      derivedDirectory: root.appendingPathComponent("Evidence/Derived", isDirectory: true)
    )
    auditEvents = SQLiteAuditEventRepository(connection: connection)
  }

  public static func openDefault() throws -> BlueprintDatabase {
    let layout = try StorageLayout.applicationSupport()
    try layout.createDirectories()
    return try BlueprintDatabase(
      databaseURL: layout.databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: layout.automaticBackupDirectory)
    )
  }

  public func createInitialSetup(
    profile: BusinessProfile,
    fiscalYear: FiscalYear,
    at date: Date
  ) throws {
    try connection.transaction {
      guard try profiles.fetchAll().isEmpty else {
        throw RepositoryError.duplicate("Initial setup already exists")
      }
      try fiscalYears.save(fiscalYear)
      try profiles.save(profile)
      try accounts.seedStandardAccounts(createdAt: date)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "FiscalYear",
          targetID: fiscalYear.id.uuidString.lowercased()
        )
      )
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
      for account in StandardChartOfAccounts.accounts(createdAt: date) {
        try auditEvents.append(
          AuditEvent(
            occurredAt: date,
            actorKind: .system,
            action: .created,
            targetType: "Account",
            targetID: account.id.uuidString.lowercased(),
            reason: "standard-chart"
          )
        )
      }
    }
  }

  public func saveProfile(_ profile: BusinessProfile, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetch(id: profile.fiscalYearID)?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      let exists = try profiles.fetch(id: profile.id) != nil
      try profiles.save(profile)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: exists ? .updated : .created,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
    }
  }

  public func saveAccount(_ account: Account, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetchAll().first?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      let exists = try accounts.fetchAll(includeInactive: true).contains { $0.id == account.id }
      try accounts.save(account)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: exists ? .updated : .created,
          targetType: "Account",
          targetID: account.id.uuidString.lowercased()
        )
      )
    }
  }

  public func deactivateAccount(id: EntityID, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetchAll().first?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      try accounts.deactivate(id: id, at: date)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .deactivated,
          targetType: "Account",
          targetID: id.uuidString.lowercased()
        )
      )
    }
  }

  public func lockFiscalYear(id: EntityID, at date: Date) throws {
    try connection.transaction {
      guard var fiscalYear = try fiscalYears.fetch(id: id) else { throw RepositoryError.notFound }
      fiscalYear.lock(at: date)
      try fiscalYears.save(fiscalYear)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .fiscalYearLocked,
          targetType: "FiscalYear",
          targetID: id.uuidString.lowercased()
        )
      )
    }
  }

  public func reopenFiscalYear(id: EntityID, reason: String, at date: Date) throws {
    try connection.transaction {
      guard var fiscalYear = try fiscalYears.fetch(id: id) else { throw RepositoryError.notFound }
      try fiscalYear.reopen(reason: reason, at: date)
      try fiscalYears.save(fiscalYear)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .fiscalYearReopened,
          targetType: "FiscalYear",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
    }
  }

  public func saveJournalDraft(_ entry: JournalEntry, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetch(id: entry.fiscalYearID)?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      if let existing = try journals.fetch(id: entry.id), existing.status == .posted {
        throw JournalError.cannotModifyPostedEntry
      }
      guard entry.status == .draft || entry.status == .pendingReview else {
        throw JournalError.cannotModifyPostedEntry
      }
      try journals.persist(entry)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "JournalEntry",
          targetID: entry.id.uuidString.lowercased()
        )
      )
    }
  }

  public func postJournal(id: EntityID, fiscalYearID: EntityID, at date: Date) throws {
    try connection.transaction {
      guard let fiscalYear = try fiscalYears.fetch(id: fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard var entry = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      try entry.post(for: fiscalYear, at: date)
      try journals.persist(entry)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: "posted"
        )
      )
    }
  }

  @discardableResult
  public func reverseJournal(id: EntityID, reason: String, at date: Date) throws -> JournalEntry {
    try connection.transaction {
      guard var original = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      guard let fiscalYear = try fiscalYears.fetch(id: original.fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
      var reversal = try original.makeReversal(at: date, reason: reason)
      try reversal.post(for: fiscalYear, at: date)
      original.status = .reversed
      original.metadata.touch(at: date)
      try journals.persist(original)
      try journals.persist(reversal)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .cancelled,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
      return reversal
    }
  }

  @discardableResult
  public func correctJournal(
    id: EntityID,
    transactionDate: Date,
    description: String,
    lines: [JournalLine],
    reason: String,
    at date: Date
  ) throws -> (reversal: JournalEntry, correction: JournalEntry) {
    try connection.transaction {
      guard var original = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      guard let fiscalYear = try fiscalYears.fetch(id: original.fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
      var reversal = try original.makeReversal(at: date, reason: reason)
      var correction = try original.makeCorrection(
        metadata: EntityMetadata(createdAt: date),
        transactionDate: transactionDate,
        description: description,
        lines: lines,
        reason: reason
      )
      try reversal.post(for: fiscalYear, at: date)
      try correction.post(for: fiscalYear, at: date)
      original.status = .corrected
      original.metadata.touch(at: date)
      try journals.persist(original)
      try journals.persist(reversal)
      try journals.persist(correction)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .corrected,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
      return (reversal, correction)
    }
  }

  @discardableResult
  public func importEvidence(
    from source: URL,
    mimeType: String,
    origin: EvidenceOrigin,
    at date: Date
  ) throws -> EvidenceDocument {
    guard try fiscalYears.fetchAll().first?.status != .locked else {
      throw RepositoryError.fiscalYearLocked
    }
    let fingerprint = try evidenceFileStore.fingerprint(source)
    if let existing = try evidence.fetch(sha256: fingerprint.sha256) {
      throw EvidenceError.exactDuplicate(existingID: existing.id)
    }
    let id = UUID()
    let stored = try evidenceFileStore.importOriginal(
      from: source,
      documentID: id,
      mimeType: mimeType
    )
    let document = EvidenceDocument(
      metadata: EntityMetadata(id: id, createdAt: date),
      originalSHA256: stored.sha256,
      originalRelativePath: stored.relativePath,
      originalFilename: source.lastPathComponent,
      mimeType: stored.mimeType,
      byteCount: stored.byteCount,
      acquiredAt: date,
      origin: origin
    )
    do {
      try connection.transaction {
        try evidence.save(document)
        try auditEvents.append(
          AuditEvent(
            occurredAt: date,
            actorKind: .localUser,
            action: .created,
            targetType: "EvidenceDocument",
            targetID: document.id.uuidString.lowercased(),
            reason: origin.rawValue
          )
        )
      }
      return document
    } catch {
      let createdURL = evidenceFileStore.originalURL(relativePath: stored.relativePath)
      try? FileManager.default.removeItem(at: createdURL)
      throw error
    }
  }

  @discardableResult
  public func processOCR(
    evidenceID: EntityID,
    recognizer: any OCRRecognizing = OnDeviceOCRPipeline(),
    at date: Date
  ) throws -> [OCRCandidate] {
    guard var document = try evidence.fetch(id: evidenceID) else { throw RepositoryError.notFound }
    let url = evidenceFileStore.originalURL(relativePath: document.originalRelativePath)
    let candidates = OCRCandidateExtractor.extract(
      evidenceID: evidenceID,
      lines: try recognizer.recognize(url: url)
    )
    document.state = .needsReview
    document.transactionDate = Self.bestDate(candidates)
    document.amount = Self.bestAmount(candidates)
    document.counterparty = Self.bestValue(.counterparty, candidates: candidates)
    document.metadata.touch(at: date)
    try connection.transaction {
      for candidate in candidates { try evidence.appendCandidate(candidate) }
      try evidence.save(document)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .system,
          action: .updated,
          targetType: "EvidenceDocument",
          targetID: evidenceID.uuidString.lowercased(),
          reason: "on-device-ocr-candidates"
        )
      )
    }
    return candidates
  }

  public func correctOCRCandidate(
    id: EntityID,
    evidenceID: EntityID,
    value: String,
    at date: Date
  ) throws {
    guard
      var candidate = try evidence.candidates(evidenceID: evidenceID).first(where: { $0.id == id })
    else { throw RepositoryError.notFound }
    let previous = candidate.effectiveValue
    candidate.correctedValue = value
    candidate.correctedAt = date
    try connection.transaction {
      try evidence.appendCandidate(candidate)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "OCRCandidate",
          targetID: id.uuidString.lowercased(),
          reason: "\(candidate.field.rawValue): \(previous) -> \(value)"
        )
      )
    }
  }

  @discardableResult
  public func confirmEvidenceAndPost(
    evidenceID: EntityID,
    fiscalYearID: EntityID,
    expenseAccountID: EntityID,
    paymentAccountID: EntityID,
    transactionDate: Date,
    amount: Money,
    counterparty: String,
    description: String,
    taxSelection: TaxSelection,
    roundingUnit: RoundingUnit,
    at date: Date
  ) throws -> JournalEntry {
    guard amount.yen > 0 else { throw JournalError.amountMustBePositive }
    guard var document = try evidence.fetch(id: evidenceID) else { throw RepositoryError.notFound }
    guard document.state == .needsReview || document.state == .unprocessed else {
      throw EvidenceError.confirmationRequired
    }
    guard let fiscalYear = try fiscalYears.fetch(id: fiscalYearID) else {
      throw RepositoryError.notFound
    }
    let treatment = TransitionalTaxRuleResolver.resolve(
      selection: taxSelection,
      transactionDate: transactionDate,
      roundingUnit: roundingUnit
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: transactionDate,
      description: description,
      lines: [
        try JournalLine(
          accountID: expenseAccountID,
          side: .debit,
          amount: amount,
          taxRate: treatment.selection.taxRate,
          invoiceStatus: treatment.selection.invoiceStatus,
          deductibleBasisPoints: treatment.deductibleBasisPoints,
          roundingUnit: treatment.roundingUnit,
          counterparty: counterparty
        ),
        try JournalLine(
          accountID: paymentAccountID,
          side: .credit,
          amount: amount,
          taxRate: .outOfScope,
          roundingUnit: roundingUnit,
          counterparty: counterparty
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    document.state = .posted
    document.transactionDate = transactionDate
    document.amount = amount
    document.counterparty = counterparty
    document.metadata.touch(at: date)
    try connection.transaction {
      try journals.persist(entry)
      try evidence.save(document)
      try evidence.link(
        EvidenceLink(
          evidenceID: evidenceID,
          journalEntryID: entry.id,
          linkedAt: date
        ))
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "EvidenceDocument",
          targetID: evidenceID.uuidString.lowercased(),
          reason: "confirmed-and-posted"
        )
      )
    }
    return entry
  }

  public func importCSV(
    data: Data,
    filename: String,
    profile: ImportProfile,
    at date: Date
  ) throws -> ImportBatch {
    guard try fiscalYears.fetchAll().first?.status != .locked else {
      throw RepositoryError.fiscalYearLocked
    }
    let existing = try imports.transactions(states: Set(ImportedTransactionState.allCases))
    let batch = try CSVImporter.makeBatch(
      data: data,
      filename: filename,
      profile: profile,
      existing: existing,
      importedAt: date
    )
    try connection.transaction {
      try imports.saveProfile(profile)
      try imports.persistBatch(batch)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .importer,
          action: .created,
          targetType: "ImportBatch",
          targetID: batch.id.uuidString.lowercased(),
          reason: "\(batch.transactions.count) rows, \(batch.errors.count) errors"
        )
      )
    }
    return batch
  }

  public func evidenceCandidates(
    for transactionID: EntityID
  ) throws -> [TransactionEvidenceCandidate] {
    let all = try imports.transactions(states: Set(ImportedTransactionState.allCases))
    guard let transaction = all.first(where: { $0.id == transactionID }) else {
      throw RepositoryError.notFound
    }
    let dayStart = Calendar(identifier: .gregorian).startOfDay(for: transaction.transactionDate)
    let dayEnd = Calendar(identifier: .gregorian)
      .date(byAdding: .day, value: 1, to: dayStart)!
      .addingTimeInterval(-0.001)
    let documents = try evidence.search(
      EvidenceSearch(
        dateRange: dayStart...dayEnd,
        amount: Money(yen: abs(transaction.amount.yen))
      ))
    let normalizedDescription = transaction.description.normalizedForEvidenceMatch
    return documents.map { document in
      var score = 0.75
      var reasons = ["日付一致", "金額一致"]
      if let counterparty = document.counterparty?.normalizedForEvidenceMatch,
        !counterparty.isEmpty,
        normalizedDescription.contains(counterparty)
          || counterparty.contains(normalizedDescription)
      {
        score = 1
        reasons.append("取引先一致")
      }
      return TransactionEvidenceCandidate(
        evidenceID: document.id,
        score: score,
        reasons: reasons
      )
    }.sorted { $0.score > $1.score }
  }

  public func associateEvidence(
    transactionID: EntityID,
    evidenceID: EntityID,
    at date: Date
  ) throws {
    let all = try imports.transactions(states: Set(ImportedTransactionState.allCases))
    guard var transaction = all.first(where: { $0.id == transactionID }) else {
      throw RepositoryError.notFound
    }
    guard try evidence.fetch(id: evidenceID) != nil else { throw RepositoryError.notFound }
    transaction.evidenceID = evidenceID
    transaction.state = .needsReview
    try connection.transaction {
      try imports.updateTransaction(transaction)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "ImportedTransaction",
          targetID: transactionID.uuidString.lowercased(),
          reason: "evidence-associated:\(evidenceID.uuidString.lowercased())"
        ))
    }
  }

  @discardableResult
  public func confirmImportedTransaction(
    transactionID: EntityID,
    fiscalYearID: EntityID,
    expenseAccountID: EntityID,
    paymentAccountID: EntityID,
    taxSelection: TaxSelection,
    roundingUnit: RoundingUnit,
    at date: Date
  ) throws -> JournalEntry {
    let all = try imports.transactions(states: Set(ImportedTransactionState.allCases))
    guard var transaction = all.first(where: { $0.id == transactionID }) else {
      throw RepositoryError.notFound
    }
    guard transaction.state != .posted, transaction.state != .excluded else {
      throw EvidenceError.confirmationRequired
    }
    guard let fiscalYear = try fiscalYears.fetch(id: fiscalYearID) else {
      throw RepositoryError.notFound
    }
    let amount = Money(yen: abs(transaction.amount.yen))
    guard amount.yen > 0 else { throw JournalError.amountMustBePositive }
    let treatment = TransitionalTaxRuleResolver.resolve(
      selection: taxSelection,
      transactionDate: transaction.transactionDate,
      roundingUnit: roundingUnit
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: transaction.transactionDate,
      description: transaction.description,
      lines: [
        try JournalLine(
          accountID: expenseAccountID,
          side: .debit,
          amount: amount,
          taxRate: treatment.selection.taxRate,
          invoiceStatus: treatment.selection.invoiceStatus,
          deductibleBasisPoints: treatment.deductibleBasisPoints,
          roundingUnit: treatment.roundingUnit,
          counterparty: transaction.description
        ),
        try JournalLine(
          accountID: paymentAccountID,
          side: .credit,
          amount: amount,
          taxRate: .outOfScope,
          roundingUnit: roundingUnit
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    transaction.state = .posted
    transaction.journalEntryID = entry.id
    try connection.transaction {
      try journals.persist(entry)
      try imports.updateTransaction(transaction)
      if let evidenceID = transaction.evidenceID {
        try evidence.link(
          EvidenceLink(evidenceID: evidenceID, journalEntryID: entry.id, linkedAt: date)
        )
      }
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "ImportedTransaction",
          targetID: transactionID.uuidString.lowercased(),
          reason: "confirmed-and-posted"
        ))
    }
    return entry
  }

  public func reconcile(
    statementBalance: Money,
    bankAccountID: EntityID,
    fiscalYearID: EntityID
  ) throws -> BankReconciliation {
    let entries = try journals.search(JournalSearch(fiscalYearID: fiscalYearID))
    let bookBalance =
      try AccountingReports.ledger(accountID: bankAccountID, entries: entries)
      .last?.runningBalance ?? .zero
    return BankReconciliation(statementBalance: statementBalance, bookBalance: bookBalance)
  }

  public func saveCounterparty(_ counterparty: Counterparty, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetchAll().first?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      let exists = try billing.counterparties(includeInactive: true).contains {
        $0.id == counterparty.id
      }
      try billing.saveCounterparty(counterparty)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: exists ? .updated : .created,
          targetType: "Counterparty",
          targetID: counterparty.id.uuidString.lowercased()
        ))
    }
  }

  @discardableResult
  public func issueInvoice(
    _ proposedInvoice: Invoice,
    accounts: InvoiceIssueAccounts,
    at date: Date
  ) throws -> Invoice {
    if let existing = try billing.invoice(id: proposedInvoice.id), existing.journalEntryID != nil {
      return existing
    }
    guard let fiscalYear = try fiscalYears.fetch(id: proposedInvoice.fiscalYearID) else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    guard
      let counterparty = try billing.counterparties(includeInactive: true).first(where: {
        $0.id == proposedInvoice.counterpartyID
      })
    else { throw RepositoryError.notFound }
    if let duplicate = try billing.invoice(number: proposedInvoice.number),
      duplicate.id != proposedInvoice.id
    {
      throw BillingError.duplicateNumber
    }
    var sourceInvoice: Invoice?
    var sourceJournal: JournalEntry?
    var sourceReversal: JournalEntry?
    if proposedInvoice.kind != .standard {
      guard let sourceID = proposedInvoice.sourceInvoiceID,
        var source = try billing.invoice(id: sourceID),
        source.status != .draft,
        source.status != .cancelled
      else { throw BillingError.invalidStateTransition }
      if proposedInvoice.kind == .correction {
        guard source.status == .issued || source.status == .overdue,
          source.settlements.isEmpty,
          let sourceJournalID = source.journalEntryID,
          var originalJournal = try journals.fetch(id: sourceJournalID)
        else { throw BillingError.invalidStateTransition }
        var reversal = try originalJournal.makeReversal(
          at: date,
          reason: proposedInvoice.reason ?? "請求訂正"
        )
        try reversal.post(for: fiscalYear, at: date)
        originalJournal.status = .reversed
        originalJournal.metadata.touch(at: date)
        sourceJournal = originalJournal
        sourceReversal = reversal
      }
      source.status = proposedInvoice.kind == .refund ? .refunded : .corrected
      source.metadata.touch(at: date)
      sourceInvoice = source
    }
    try proposedInvoice.validateForIssue()
    let pdf = try InvoicePDFRenderer.render(
      invoice: proposedInvoice,
      recipient: InvoicePDFRecipient(
        name: counterparty.displayName,
        postalCode: counterparty.postalCode,
        address: counterparty.address
      )
    )
    let prepared = try prepareGeneratedEvidence(
      data: pdf,
      filename: "\(proposedInvoice.number).pdf",
      transactionDate: proposedInvoice.issueDate,
      amount: try proposedInvoice.total(),
      counterparty: counterparty.displayName,
      at: date
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: proposedInvoice.fiscalYearID,
      transactionDate: proposedInvoice.issueDate,
      description: "請求 \(proposedInvoice.number) \(proposedInvoice.subject)",
      lines: try invoiceIssueLines(
        invoice: proposedInvoice,
        accounts: accounts,
        counterparty: counterparty.displayName
      )
    )
    try entry.post(for: fiscalYear, at: date)
    var invoice = proposedInvoice
    try invoice.markIssued(
      journalEntryID: entry.id,
      evidenceID: prepared.document.id,
      at: date
    )
    do {
      try connection.transaction {
        if let sourceJournal { try journals.persist(sourceJournal) }
        if let sourceReversal { try journals.persist(sourceReversal) }
        try journals.persist(entry)
        if prepared.createdURL != nil { try evidence.save(prepared.document) }
        try evidence.link(
          EvidenceLink(
            evidenceID: prepared.document.id,
            journalEntryID: entry.id,
            linkedAt: date
          ))
        try billing.saveInvoice(invoice)
        if let sourceInvoice { try billing.saveInvoice(sourceInvoice) }
        try auditEvents.append(
          AuditEvent(
            occurredAt: date,
            actorKind: .localUser,
            action: .created,
            targetType: "Invoice",
            targetID: invoice.id.uuidString.lowercased(),
            reason: "issued:\(invoice.number)"
          ))
      }
      return invoice
    } catch {
      if let createdURL = prepared.createdURL {
        try? FileManager.default.removeItem(at: createdURL)
      }
      throw error
    }
  }

  @discardableResult
  public func reissueInvoice(id: EntityID, reason: String, at date: Date) throws -> InvoiceReissue {
    guard let invoice = try billing.invoice(id: id) else { throw RepositoryError.notFound }
    guard invoice.status != .draft, invoice.status != .cancelled else {
      throw BillingError.invalidStateTransition
    }
    let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw BillingError.missingReason }
    guard
      let counterparty = try billing.counterparties(includeInactive: true).first(where: {
        $0.id == invoice.counterpartyID
      })
    else { throw RepositoryError.notFound }
    let pdf = try InvoicePDFRenderer.render(
      invoice: invoice,
      recipient: InvoicePDFRecipient(
        name: counterparty.displayName,
        postalCode: counterparty.postalCode,
        address: counterparty.address
      )
    )
    let prepared = try prepareGeneratedEvidence(
      data: pdf,
      filename: "\(invoice.number)-reissue.pdf",
      transactionDate: invoice.issueDate,
      amount: try invoice.total(),
      counterparty: counterparty.displayName,
      at: date
    )
    let sequence = try billing.reissues(invoiceID: id).count + 1
    let reissue = InvoiceReissue(
      id: UUID(),
      invoiceID: id,
      sequence: sequence,
      issuedAt: date,
      reason: normalized,
      evidenceID: prepared.document.id
    )
    do {
      try connection.transaction {
        if prepared.createdURL != nil { try evidence.save(prepared.document) }
        try billing.appendReissue(reissue)
        try auditEvents.append(
          AuditEvent(
            occurredAt: date,
            actorKind: .localUser,
            action: .created,
            targetType: "InvoiceReissue",
            targetID: reissue.id.uuidString.lowercased(),
            reason: normalized
          ))
      }
      return reissue
    } catch {
      if let createdURL = prepared.createdURL {
        try? FileManager.default.removeItem(at: createdURL)
      }
      throw error
    }
  }

  @discardableResult
  public func settleInvoice(
    invoiceID: EntityID,
    settlement: InvoiceSettlement,
    accounts: ReceivableSettlementAccounts,
    at date: Date
  ) throws -> Invoice {
    guard var invoice = try billing.invoice(id: invoiceID) else { throw RepositoryError.notFound }
    guard let fiscalYear = try fiscalYears.fetch(id: invoice.fiscalYearID) else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    var lines: [JournalLine] = []
    try appendLine(
      to: &lines,
      accountID: accounts.bankAccountID,
      side: .debit,
      amount: settlement.cashReceived
    )
    try appendLine(
      to: &lines,
      accountID: accounts.bankFeeAccountID,
      side: .debit,
      amount: settlement.bankFee
    )
    try appendLine(
      to: &lines,
      accountID: accounts.withholdingAccountID,
      side: .debit,
      amount: settlement.withholdingTax
    )
    try appendLine(
      to: &lines,
      accountID: accounts.discountAccountID,
      side: .debit,
      amount: settlement.discount
    )
    try appendLine(
      to: &lines,
      accountID: accounts.receivableAccountID,
      side: .credit,
      amount: settlement.appliedAmount
    )
    try appendLine(
      to: &lines,
      accountID: accounts.overpaymentAccountID,
      side: .credit,
      amount: settlement.overpayment
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: invoice.fiscalYearID,
      transactionDate: settlement.receivedAt,
      description: "入金消込 \(invoice.number)",
      lines: lines
    )
    try entry.post(for: fiscalYear, at: date)
    let recorded = try InvoiceSettlement(
      id: settlement.id,
      receivedAt: settlement.receivedAt,
      appliedAmount: settlement.appliedAmount,
      cashReceived: settlement.cashReceived,
      bankFee: settlement.bankFee,
      withholdingTax: settlement.withholdingTax,
      discount: settlement.discount,
      overpayment: settlement.overpayment,
      sourceTransactionID: settlement.sourceTransactionID,
      journalEntryID: entry.id
    )
    try invoice.applySettlement(recorded, at: date)
    try connection.transaction {
      try journals.persist(entry)
      try billing.saveInvoice(invoice)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "Invoice",
          targetID: invoice.id.uuidString.lowercased(),
          reason: "settlement:\(recorded.appliedAmount.yen)"
        ))
    }
    return invoice
  }

  @discardableResult
  public func settleInvoices(
    allocations: [(invoiceID: EntityID, appliedAmount: Money)],
    bankAccountID: EntityID,
    receivableAccountID: EntityID,
    sourceTransactionID: EntityID? = nil,
    at date: Date
  ) throws -> [Invoice] {
    guard !allocations.isEmpty, allocations.allSatisfy({ $0.appliedAmount.yen > 0 }) else {
      throw BillingError.invalidAmount
    }
    var invoices: [Invoice] = []
    for allocation in allocations {
      guard let invoice = try billing.invoice(id: allocation.invoiceID) else {
        throw RepositoryError.notFound
      }
      guard allocation.appliedAmount <= (try invoice.outstandingAmount()) else {
        throw BillingError.settlementExceedsOutstanding
      }
      invoices.append(invoice)
    }
    guard let fiscalYearID = invoices.first?.fiscalYearID,
      invoices.allSatisfy({ $0.fiscalYearID == fiscalYearID }),
      let fiscalYear = try fiscalYears.fetch(id: fiscalYearID)
    else { throw BillingError.invalidStateTransition }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    let total = Money(yen: allocations.reduce(0) { $0 + $1.appliedAmount.yen })
    var lines = [
      try JournalLine(accountID: bankAccountID, side: .debit, amount: total)
    ]
    for (index, allocation) in allocations.enumerated() {
      lines.append(
        try JournalLine(
          accountID: receivableAccountID,
          side: .credit,
          amount: allocation.appliedAmount,
          memo: invoices[index].number
        ))
    }
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: date,
      description: "合算入金消込 \(allocations.count)件",
      lines: lines
    )
    try entry.post(for: fiscalYear, at: date)
    for index in invoices.indices {
      let allocation = allocations[index]
      let settlement = try InvoiceSettlement(
        receivedAt: date,
        appliedAmount: allocation.appliedAmount,
        cashReceived: allocation.appliedAmount,
        sourceTransactionID: sourceTransactionID,
        journalEntryID: entry.id
      )
      try invoices[index].applySettlement(settlement, at: date)
    }
    try connection.transaction {
      try journals.persist(entry)
      for invoice in invoices { try billing.saveInvoice(invoice) }
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "InvoiceSettlementBatch",
          targetID: entry.id.uuidString.lowercased(),
          reason: "allocations:\(allocations.count)"
        ))
    }
    return invoices
  }

  @discardableResult
  public func cancelInvoice(id: EntityID, reason: String, at date: Date) throws -> Invoice {
    guard var invoice = try billing.invoice(id: id), let journalID = invoice.journalEntryID else {
      throw RepositoryError.notFound
    }
    guard var original = try journals.fetch(id: journalID) else { throw RepositoryError.notFound }
    guard let fiscalYear = try fiscalYears.fetch(id: invoice.fiscalYearID) else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    var reversal = try original.makeReversal(at: date, reason: reason)
    try reversal.post(for: fiscalYear, at: date)
    try invoice.cancel(reason: reason, at: date)
    original.status = .reversed
    original.metadata.touch(at: date)
    try connection.transaction {
      try journals.persist(original)
      try journals.persist(reversal)
      try billing.saveInvoice(invoice)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .cancelled,
          targetType: "Invoice",
          targetID: id.uuidString.lowercased(),
          reason: reason
        ))
    }
    return invoice
  }

  @discardableResult
  public func confirmVendorBill(
    _ proposedBill: VendorBill,
    accounts: VendorBillAccounts,
    at date: Date
  ) throws -> VendorBill {
    if let existing = try billing.vendorBill(id: proposedBill.id), existing.journalEntryID != nil {
      return existing
    }
    guard let fiscalYear = try fiscalYears.fetch(id: proposedBill.fiscalYearID) else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    let amount = try proposedBill.grossAmount()
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: proposedBill.fiscalYearID,
      transactionDate: proposedBill.issueDate,
      description: "外注請求 \(proposedBill.referenceNumber) \(proposedBill.description)",
      lines: [
        try JournalLine(
          accountID: accounts.expenseAccountID,
          side: .debit,
          amount: amount,
          taxRate: proposedBill.lines.first?.taxRate ?? .outOfScope,
          invoiceStatus: proposedBill.invoiceStatus
        ),
        try JournalLine(
          accountID: accounts.payableAccountID,
          side: .credit,
          amount: amount
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    var bill = proposedBill
    try bill.confirm(journalEntryID: entry.id, at: date)
    try connection.transaction {
      try journals.persist(entry)
      try billing.saveVendorBill(bill)
      if let evidenceID = bill.evidenceID {
        try evidence.link(
          EvidenceLink(evidenceID: evidenceID, journalEntryID: entry.id, linkedAt: date))
      }
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "VendorBill",
          targetID: bill.id.uuidString.lowercased(),
          reason: "confirmed:\(bill.referenceNumber)"
        ))
    }
    return bill
  }

  @discardableResult
  public func settleVendorBill(
    billID: EntityID,
    payment: VendorBillPayment,
    accounts: VendorPaymentAccounts,
    at date: Date
  ) throws -> VendorBill {
    guard var bill = try billing.vendorBill(id: billID) else { throw RepositoryError.notFound }
    guard let fiscalYear = try fiscalYears.fetch(id: bill.fiscalYearID) else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    var lines: [JournalLine] = []
    try appendLine(
      to: &lines,
      accountID: accounts.payableAccountID,
      side: .debit,
      amount: payment.appliedAmount
    )
    try appendLine(
      to: &lines,
      accountID: accounts.bankFeeAccountID,
      side: .debit,
      amount: payment.bankFee
    )
    try appendLine(
      to: &lines,
      accountID: accounts.bankAccountID,
      side: .credit,
      amount: Money(yen: payment.cashPaid.yen + payment.bankFee.yen)
    )
    try appendLine(
      to: &lines,
      accountID: accounts.withholdingAccountID,
      side: .credit,
      amount: payment.withholdingTax
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: bill.fiscalYearID,
      transactionDate: payment.paidAt,
      description: "外注支払消込 \(bill.referenceNumber)",
      lines: lines
    )
    try entry.post(for: fiscalYear, at: date)
    let recorded = try VendorBillPayment(
      id: payment.id,
      paidAt: payment.paidAt,
      appliedAmount: payment.appliedAmount,
      cashPaid: payment.cashPaid,
      withholdingTax: payment.withholdingTax,
      bankFee: payment.bankFee,
      sourceTransactionID: payment.sourceTransactionID,
      journalEntryID: entry.id
    )
    try bill.applyPayment(recorded, at: date)
    try connection.transaction {
      try journals.persist(entry)
      try billing.saveVendorBill(bill)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "VendorBill",
          targetID: bill.id.uuidString.lowercased(),
          reason: "payment:\(recorded.appliedAmount.yen)"
        ))
    }
    return bill
  }

  private func invoiceIssueLines(
    invoice: Invoice,
    accounts: InvoiceIssueAccounts,
    counterparty: String
  ) throws -> [JournalLine] {
    let receivableSide: PostingSide = invoice.kind == .refund ? .credit : .debit
    let revenueSide: PostingSide = invoice.kind == .refund ? .debit : .credit
    var lines = [
      try JournalLine(
        accountID: accounts.receivableAccountID,
        side: receivableSide,
        amount: invoice.total(),
        counterparty: counterparty
      )
    ]
    for summary in try invoice.taxSummaries() {
      lines.append(
        try JournalLine(
          accountID: accounts.revenueAccountID,
          side: revenueSide,
          amount: summary.grossAmount,
          taxRate: summary.taxRate,
          invoiceStatus: invoice.issuerRegistrationStatus,
          roundingUnit: .invoice,
          counterparty: counterparty,
          memo: "税抜\(summary.netAmount.yen) 税\(summary.taxAmount.yen)"
        ))
    }
    return lines
  }

  private func appendLine(
    to lines: inout [JournalLine],
    accountID: EntityID,
    side: PostingSide,
    amount: Money
  ) throws {
    guard amount.yen > 0 else { return }
    lines.append(try JournalLine(accountID: accountID, side: side, amount: amount))
  }

  private func prepareGeneratedEvidence(
    data: Data,
    filename: String,
    transactionDate: Date,
    amount: Money,
    counterparty: String,
    at date: Date
  ) throws -> (document: EvidenceDocument, createdURL: URL?) {
    let fingerprint = try evidenceFileStore.fingerprint(data)
    if let existing = try evidence.fetch(sha256: fingerprint.sha256) {
      return (existing, nil)
    }
    let id = UUID()
    let stored = try evidenceFileStore.importOriginal(
      data: data,
      documentID: id,
      fileExtension: "pdf",
      mimeType: "application/pdf"
    )
    let document = EvidenceDocument(
      metadata: EntityMetadata(id: id, createdAt: date),
      originalSHA256: stored.sha256,
      originalRelativePath: stored.relativePath,
      originalFilename: filename,
      mimeType: stored.mimeType,
      byteCount: stored.byteCount,
      acquiredAt: date,
      origin: .electronicTransaction,
      state: .posted,
      transactionDate: transactionDate,
      amount: amount,
      counterparty: counterparty
    )
    return (
      document,
      evidenceFileStore.originalURL(relativePath: stored.relativePath)
    )
  }

  private static func bestValue(_ field: OCRField, candidates: [OCRCandidate]) -> String? {
    candidates.filter { $0.field == field }.max { $0.confidence < $1.confidence }?.effectiveValue
  }

  private static func bestAmount(_ candidates: [OCRCandidate]) -> Money? {
    guard let value = bestValue(.amount, candidates: candidates) else { return nil }
    let digits = value.filter(\.isNumber)
    return Int64(digits).map(Money.init(yen:))
  }

  private static func bestDate(_ candidates: [OCRCandidate]) -> Date? {
    guard var value = bestValue(.transactionDate, candidates: candidates) else { return nil }
    value = value.replacingOccurrences(of: "年", with: "/")
      .replacingOccurrences(of: "月", with: "/")
      .replacingOccurrences(of: "日", with: "")
      .replacingOccurrences(of: ".", with: "/")
      .replacingOccurrences(of: "-", with: "/")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP_POSIX")
    formatter.dateFormat = "yyyy/M/d"
    return formatter.date(from: value)
  }

  public func isSetupComplete() throws -> Bool {
    let hasProfile = try !profiles.fetchAll().isEmpty
    let hasFiscalYear = try !fiscalYears.fetchAll().isEmpty
    return hasProfile && hasFiscalYear
  }
}

extension String {
  fileprivate var normalizedForEvidenceMatch: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "　", with: "")
  }
}
