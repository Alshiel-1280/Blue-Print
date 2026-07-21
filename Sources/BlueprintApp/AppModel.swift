import BlueprintAudit
import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import BlueprintPersistence
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var profile: BusinessProfile?
  @Published private(set) var fiscalYear: FiscalYear?
  @Published private(set) var accounts: [Account] = []
  @Published private(set) var journalEntries: [JournalEntry] = []
  @Published private(set) var auditEvents: [AuditEvent] = []
  @Published private(set) var evidenceDocuments: [EvidenceDocument] = []
  @Published private(set) var importBatches: [ImportBatch] = []
  @Published private(set) var importedTransactions: [ImportedTransaction] = []
  @Published private(set) var importProfiles: [ImportProfile] = []
  @Published private(set) var isLoading = true
  @Published var errorMessage: String?

  private var database: BlueprintDatabase?
  private let clock: any BlueprintClock

  init(database: BlueprintDatabase? = nil, clock: any BlueprintClock = SystemClock()) {
    self.clock = clock
    do {
      self.database = try database ?? Self.makeDefaultDatabase()
      try reload()
    } catch {
      self.database = nil
      errorMessage = Self.userFacingMessage(for: error)
    }
    isLoading = false
  }

  var isSetupComplete: Bool { profile != nil && fiscalYear != nil }

  func createInitialSetup(
    ownerName: String,
    tradeName: String,
    calendarYear: Int,
    consumptionTaxStatus: ConsumptionTaxStatus,
    invoiceStatus: InvoiceRegistrationStatus,
    bookkeepingStyle: BookkeepingStyle,
    taxAccountingMethod: TaxAccountingMethod,
    roundingRule: RoundingRule
  ) {
    guard let database else {
      errorMessage = "データベースを開けないため保存できません。アプリを再起動し、改善しない場合は保存先の権限を確認してください。"
      return
    }
    let normalizedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTradeName = tradeName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedOwner.isEmpty else {
      errorMessage = "氏名が未入力です。申告する本人の氏名を入力してください。"
      return
    }
    guard !normalizedTradeName.isEmpty else {
      errorMessage = "屋号が未入力です。屋号がない場合は、氏名と同じ内容を入力してください。"
      return
    }

    do {
      let now = clock.now()
      let fiscalYear = try FiscalYear(
        metadata: EntityMetadata(createdAt: now),
        calendarYear: calendarYear,
        taxRuleSetID: BlueprintVersions.taxRuleSet,
        formRuleSetID: BlueprintVersions.formRuleSet
      )
      let profile = BusinessProfile(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: fiscalYear.id,
        ownerName: normalizedOwner,
        tradeName: normalizedTradeName,
        bookkeepingStyle: bookkeepingStyle,
        consumptionTaxStatus: consumptionTaxStatus,
        invoiceRegistrationStatus: invoiceStatus,
        taxAccountingMethod: taxAccountingMethod,
        roundingRule: roundingRule
      )
      try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func updateProfile(_ updated: BusinessProfile) {
    guard let database else { return }
    do {
      var profile = updated
      profile.metadata.touch(at: clock.now())
      try database.saveProfile(profile, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveAccount(_ account: Account) {
    guard let database else { return }
    do {
      var account = account
      account.metadata.touch(at: clock.now())
      try database.saveAccount(account, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func deactivateAccount(_ account: Account) {
    guard let database else { return }
    do {
      try database.deactivateAccount(id: account.id, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func createAndPostJournal(
    transactionDate: Date,
    description: String,
    lines: [JournalLine]
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let now = clock.now()
      let entry = JournalEntry(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: fiscalYear.id,
        transactionDate: transactionDate,
        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
        lines: lines
      )
      try database.saveJournalDraft(entry, at: now)
      try database.postJournal(id: entry.id, fiscalYearID: fiscalYear.id, at: now)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func reverseJournal(_ entry: JournalEntry, reason: String) {
    guard let database else { return }
    do {
      try database.reverseJournal(id: entry.id, reason: reason, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func correctJournal(
    _ entry: JournalEntry,
    transactionDate: Date,
    description: String,
    lines: [JournalLine],
    reason: String
  ) {
    guard let database else { return }
    do {
      try database.correctJournal(
        id: entry.id,
        transactionDate: transactionDate,
        description: description,
        lines: lines,
        reason: reason,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func lockFiscalYear() {
    guard let database, let fiscalYear else { return }
    do {
      try database.lockFiscalYear(id: fiscalYear.id, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func reopenFiscalYear(reason: String) {
    guard let database, let fiscalYear else { return }
    do {
      try database.reopenFiscalYear(id: fiscalYear.id, reason: reason, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func ledger(accountID: EntityID) -> [LedgerItem] {
    (try? AccountingReports.ledger(accountID: accountID, entries: journalEntries)) ?? []
  }

  func evidenceCandidates(evidenceID: EntityID) -> [OCRCandidate] {
    guard let database else { return [] }
    return (try? database.evidence.candidates(evidenceID: evidenceID)) ?? []
  }

  func originalURL(for document: EvidenceDocument) -> URL? {
    database?.evidenceFileStore.originalURL(relativePath: document.originalRelativePath)
  }

  func importEvidence(from url: URL, origin: EvidenceOrigin) {
    guard let database else { return }
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let mimeType = Self.mimeType(for: url)
      let document = try database.importEvidence(
        from: url,
        mimeType: mimeType,
        origin: origin,
        at: clock.now()
      )
      _ = try database.processOCR(evidenceID: document.id, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func correctOCRCandidate(_ candidate: OCRCandidate, value: String) {
    guard let database else { return }
    do {
      try database.correctOCRCandidate(
        id: candidate.id,
        evidenceID: candidate.evidenceID,
        value: value,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func confirmEvidence(
    _ document: EvidenceDocument,
    transactionDate: Date,
    amount: Money,
    counterparty: String,
    description: String,
    expenseAccountID: EntityID,
    paymentAccountID: EntityID,
    taxSelection: TaxSelection,
    roundingUnit: RoundingUnit
  ) {
    guard let database, let fiscalYear else { return }
    do {
      try database.confirmEvidenceAndPost(
        evidenceID: document.id,
        fiscalYearID: fiscalYear.id,
        expenseAccountID: expenseAccountID,
        paymentAccountID: paymentAccountID,
        transactionDate: transactionDate,
        amount: amount,
        counterparty: counterparty,
        description: description,
        taxSelection: taxSelection,
        roundingUnit: roundingUnit,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func excludeEvidence(_ document: EvidenceDocument) {
    guard let database else { return }
    do {
      var document = document
      document.state = .excluded
      document.metadata.touch(at: clock.now())
      try database.evidence.save(document)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func importCSV(data: Data, filename: String, profile: ImportProfile) {
    guard let database else { return }
    do {
      _ = try database.importCSV(
        data: data,
        filename: filename,
        profile: profile,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func cancelImportBatch(_ batch: ImportBatch) {
    guard let database else { return }
    do {
      try database.imports.cancelBatch(id: batch.id)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func transactionEvidenceCandidates(transactionID: EntityID) -> [TransactionEvidenceCandidate] {
    guard let database else { return [] }
    return (try? database.evidenceCandidates(for: transactionID)) ?? []
  }

  func associateEvidence(transactionID: EntityID, evidenceID: EntityID) {
    guard let database else { return }
    do {
      try database.associateEvidence(
        transactionID: transactionID,
        evidenceID: evidenceID,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func confirmImportedTransaction(
    _ transaction: ImportedTransaction,
    expenseAccountID: EntityID,
    paymentAccountID: EntityID,
    taxSelection: TaxSelection,
    roundingUnit: RoundingUnit
  ) {
    guard let database, let fiscalYear else { return }
    do {
      try database.confirmImportedTransaction(
        transactionID: transaction.id,
        fiscalYearID: fiscalYear.id,
        expenseAccountID: expenseAccountID,
        paymentAccountID: paymentAccountID,
        taxSelection: taxSelection,
        roundingUnit: roundingUnit,
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func reconciliation(statementBalance: Money, bankAccountID: EntityID) -> BankReconciliation? {
    guard let database, let fiscalYear else { return nil }
    return try? database.reconcile(
      statementBalance: statementBalance,
      bankAccountID: bankAccountID,
      fiscalYearID: fiscalYear.id
    )
  }

  var trialBalance: TrialBalance? {
    try? AccountingReports.trialBalance(entries: journalEntries)
  }

  func dismissError() {
    errorMessage = nil
  }

  private func reload() throws {
    guard let database else { return }
    profile = try database.profiles.fetchAll().first
    fiscalYear = try database.fiscalYears.fetchAll().first
    accounts = try database.accounts.fetchAll(includeInactive: true)
    if let fiscalYear {
      journalEntries = try database.journals.search(JournalSearch(fiscalYearID: fiscalYear.id))
    } else {
      journalEntries = []
    }
    auditEvents = try database.auditEvents.fetchAll()
    evidenceDocuments = try database.evidence.search(EvidenceSearch())
    importBatches = try database.imports.batches()
    importProfiles = try database.imports.profiles()
    importedTransactions = try database.imports.transactions(
      states: Set(ImportedTransactionState.allCases)
    )
  }

  private static func userFacingMessage(for error: Error) -> String {
    switch error {
    case RepositoryError.physicalDeletionForbidden:
      "使用履歴を守るため勘定科目は削除できません。代わりに無効化してください。"
    case RepositoryError.duplicate:
      "同じデータが既にあります。内容を確認して重複を解消してください。"
    case FiscalYearError.unsupportedCalendarYear:
      "対応範囲外の年度です。2000年から2100年の範囲で入力してください。"
    case JournalError.debitsAndCreditsDoNotMatch(let debits, let credits):
      "借方 \(debits)円と貸方 \(credits)円が一致していません。差額を修正してください。"
    case JournalError.requiresAtLeastTwoLines:
      "仕訳には借方・貸方を含む2行以上が必要です。行を追加してください。"
    case JournalError.amountMustBePositive:
      "金額は1円以上で入力してください。"
    case JournalError.dateOutsideFiscalYear:
      "取引日が申告年度の範囲外です。年度内の日付へ修正してください。"
    case JournalError.missingReason:
      "取消・訂正の理由を入力してください。"
    case RepositoryError.fiscalYearLocked:
      "この年度はロックされています。理由を記録して再オープンしてから操作してください。"
    case EvidenceError.exactDuplicate:
      "同じ原本が既に取り込まれています。受信箱の既存証憑を確認してください。"
    case EvidenceError.originalMutationForbidden:
      "証憑原本は上書きできません。修正値は候補欄へ記録してください。"
    case EvidenceError.confirmationRequired:
      "確認済みの項目だけ転記できます。状態と入力内容を確認してください。"
    default:
      "保存処理を完了できませんでした。入力内容と保存先の空き容量を確認し、もう一度実行してください。"
    }
  }

  private static func makeDefaultDatabase() throws -> BlueprintDatabase {
    #if DEBUG
      if let root = ProcessInfo.processInfo.environment["BLUEPRINT_DATA_ROOT"], !root.isEmpty {
        let layout = StorageLayout(root: URL(fileURLWithPath: root, isDirectory: true))
        try layout.createDirectories()
        return try BlueprintDatabase(
          databaseURL: layout.databaseURL,
          backupHook: FileMigrationBackupHook(backupDirectory: layout.automaticBackupDirectory)
        )
      }
    #endif
    return try BlueprintDatabase.openDefault()
  }

  private static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "pdf": "application/pdf"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "heic": "image/heic"
    case "tif", "tiff": "image/tiff"
    default: "application/octet-stream"
    }
  }
}
