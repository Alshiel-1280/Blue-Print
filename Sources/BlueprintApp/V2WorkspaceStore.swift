import BlueprintAudit
import BlueprintBilling
import BlueprintClosing
import BlueprintDocuments
import BlueprintDomain
import BlueprintETax
import BlueprintFiling
import BlueprintImports
import BlueprintPersistence
import BlueprintTax
import BlueprintTransfer
import Combine
import Foundation

@MainActor
final class V2WorkspaceStore: ObservableObject {
  @Published private(set) var profile: BusinessProfile?
  @Published private(set) var fiscalYear: FiscalYear?
  @Published private(set) var accounts: [Account] = []
  @Published private(set) var journalEntries: [JournalEntry] = []
  @Published private(set) var evidenceDocuments: [EvidenceDocument] = []
  @Published private(set) var ocrCandidatesByEvidence: [UUID: [OCRCandidate]] = [:]
  @Published private(set) var journalTemplates: [JournalTemplateV2] = []
  @Published private(set) var journalRules: [JournalRuleV2] = []
  @Published private(set) var recurringJournals: [RecurringJournalV2] = []
  @Published private(set) var journalCandidates: [JournalCandidateV2] = []
  @Published private(set) var importCandidates: [StoredImportCandidateV2] = []
  @Published private(set) var matchCandidates: [MatchCandidateV2] = []
  @Published private(set) var counterparties: [Counterparty] = []
  @Published private(set) var invoices: [Invoice] = []
  @Published private(set) var auditEvents: [AuditEvent] = []
  @Published private(set) var closingDecisions: [ClosingDecisionV2] = []
  @Published private(set) var jobs: [JobRecord] = []
  @Published private(set) var diagnosticReport: DiagnosticReport?
  @Published private(set) var repairPlan: RepairPlan?
  @Published private(set) var updateStatus: String?
  @Published private(set) var restoreStatus: String?
  @Published private(set) var xtxStatus: String?
  @Published private(set) var isLoading = true
  @Published private(set) var isWorking = false
  @Published var selectedDestination: V2Destination = .home
  @Published var errorMessage: String?

  private var database: V2Database?
  private var ruleStore = OfficialRulePackages.store
  private let clock: any BlueprintClock

  init(clock: any BlueprintClock = SystemClock()) {
    self.clock = clock
    Task { await open() }
  }

  var isSetupComplete: Bool { profile != nil && fiscalYear != nil }
  var supportedYears: [Int] { ruleStore.supportedYears }
  func support(for year: Int) -> YearSupportMatrix? { ruleStore.support(for: year) }

  var yearSupport: YearSupportMatrix? {
    fiscalYear.flatMap { ruleStore.support(for: $0.calendarYear) }
  }

  var isFilingSupported: Bool {
    yearSupport?.supports(.incomeTaxForm) == true && yearSupport?.supports(.xtx) == true
  }

  var filingBlockers: [String] {
    guard isFilingSupported else {
      return ["この年度の所得税帳票・XTXルールは未提供です"]
    }
    var blockers = closingBlockers
    guard let profile else {
      blockers.append("事業者情報が設定されていません")
      return blockers
    }
    if profile.taxAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && profile.postalAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      blockers.append("納税地を入力してください")
    }
    if profile.taxOffice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      blockers.append("提出先税務署を入力してください")
    }
    if profile.taxOfficeCode.count != 5 || !profile.taxOfficeCode.allSatisfy(\.isNumber) {
      blockers.append("税務署番号を5桁で入力してください")
    }
    if profile.eTaxUserID.count != 16 || !profile.eTaxUserID.allSatisfy(\.isNumber) {
      blockers.append("e-Tax利用者識別番号を16桁で入力してください")
    }
    var seen: Set<String> = []
    return blockers.filter { seen.insert($0).inserted }
  }

  var trialBalance: TrialBalance? {
    try? AccountingReports.trialBalance(entries: journalEntries)
  }

  var closingBlockers: [String] {
    var blockers: [String] = []
    if journalEntries.isEmpty { blockers.append("仕訳がまだありません") }
    if trialBalance?.isBalanced == false { blockers.append("試算表の貸借が一致していません") }
    if jobs.contains(where: { $0.state == .failed || $0.state == .running }) {
      blockers.append("未完了のバックグラウンド処理があります")
    }
    if diagnosticReport?.findings.contains(where: { $0.severity == .error }) == true {
      blockers.append("診断で要確認の問題があります")
    }
    if closingDecisions.contains(where: { $0.state == .pending }) {
      blockers.append("未確認の決算判断があります")
    }
    return blockers
  }

  func accountName(_ id: EntityID) -> String {
    accounts.first(where: { $0.id == id })?.name ?? "不明な科目"
  }

  func ledger(accountID: EntityID) -> [LedgerItem] {
    (try? AccountingReports.ledger(accountID: accountID, entries: journalEntries)) ?? []
  }

  func createInitialSetup(
    ownerName: String,
    tradeName: String,
    calendarYear: Int,
    consumptionTaxStatus: ConsumptionTaxStatus,
    invoiceStatus: InvoiceRegistrationStatus
  ) {
    guard let database else { return fail("v2データベースを開けません。") }
    let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trade = tradeName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !owner.isEmpty, !trade.isEmpty else {
      return fail("氏名と屋号を入力してください。")
    }
    Task {
      await perform {
        let now = self.clock.now()
        let tax = try self.ruleStore.taxRule(for: calendarYear)
        let form = try? self.ruleStore.formRule(for: calendarYear)
        let year = try FiscalYear(
          metadata: EntityMetadata(createdAt: now),
          calendarYear: calendarYear,
          taxRuleSetID: tax.id,
          formRuleSetID: form?.id ?? "form-\(calendarYear)-unavailable"
        )
        let profile = BusinessProfile(
          metadata: EntityMetadata(createdAt: now),
          fiscalYearID: year.id,
          ownerName: owner,
          tradeName: trade,
          bookkeepingStyle: .doubleEntry,
          consumptionTaxStatus: consumptionTaxStatus,
          invoiceRegistrationStatus: invoiceStatus,
          taxAccountingMethod: .taxExclusive,
          roundingRule: .down
        )
        try await database.createInitialSetup(profile: profile, fiscalYear: year, at: now)
        try await self.reload()
      }
    }
  }

  func saveFilingIdentity(
    postalAddress: String,
    taxAddress: String,
    taxOffice: String,
    taxOfficeCode: String,
    eTaxUserID: String
  ) {
    guard let database, var updated = profile else { return }
    let now = clock.now()
    updated.postalAddress = postalAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.taxAddress = taxAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.taxOffice = taxOffice.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.taxOfficeCode = taxOfficeCode.filter(\.isNumber)
    updated.eTaxUserID = eTaxUserID.filter(\.isNumber)
    updated.metadata.touch(at: now)
    Task {
      await perform {
        try await database.updateProfile(updated, at: now)
        try await self.reload()
        self.xtxStatus = "申告者情報を保存しました。"
      }
    }
  }

  func generateXTXPackage() async -> ETaxGeneratedPackage? {
    guard !isWorking, let database, let profile, let fiscalYear else { return nil }
    guard filingBlockers.isEmpty else {
      fail(filingBlockers.joined(separator: "\n"))
      return nil
    }
    isWorking = true
    defer { isWorking = false }
    do {
      let result = try await V2XTXService().generate(
        profile: profile,
        fiscalYear: fiscalYear,
        accounts: accounts,
        journalEntries: journalEntries,
        ruleStore: ruleStore,
        database: database,
        at: clock.now()
      )
      xtxStatus =
        "XTXを生成しました。永続ジョブ \(result.jobID.uuidString.prefix(8))・SHA-256 \(result.package.hash.prefix(12))…"
      try await reload()
      return result.package
    } catch {
      fail(Self.message(for: error))
      try? await reload()
      return nil
    }
  }

  func postJournal(
    date: Date,
    description: String,
    debitAccountID: EntityID,
    creditAccountID: EntityID,
    amountYen: Int64,
    taxRate: TaxRate,
    invoiceStatus: InvoiceRegistrationStatus
  ) {
    guard let database, let fiscalYear else { return fail("年度が設定されていません。") }
    let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, amountYen > 0 else {
      return fail("摘要と1円以上の金額を入力してください。")
    }
    Task {
      await perform {
        let now = self.clock.now()
        let amount = Money(yen: amountYen)
        let entry = JournalEntry(
          metadata: EntityMetadata(createdAt: now),
          fiscalYearID: fiscalYear.id,
          transactionDate: date,
          description: normalized,
          lines: [
            try JournalLine(
              accountID: debitAccountID,
              side: .debit,
              amount: amount,
              taxRate: taxRate,
              invoiceStatus: invoiceStatus
            ),
            try JournalLine(
              accountID: creditAccountID,
              side: .credit,
              amount: amount,
              taxRate: .outOfScope,
              invoiceStatus: .unknown
            ),
          ]
        )
        try await PostV2JournalUseCase(repository: database).execute(
          entry: entry,
          fiscalYear: fiscalYear,
          at: now
        )
        try await self.reload()
      }
    }
  }

  func importEvidence(from url: URL, origin: EvidenceOrigin) {
    guard let database else { return }
    Task {
      await perform {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try await V2EvidenceService().importAndRecognize(
          sourceURL: url,
          origin: origin,
          fiscalYearID: self.fiscalYear?.id,
          database: database,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func importCSV(from url: URL, profile: ImportProfile) {
    guard let database else { return }
    Task {
      await perform {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        _ = try await V2ImportMatchingService().importCSV(
          data: data,
          filename: url.lastPathComponent,
          profile: profile,
          database: database,
          at: self.clock.now()
        )
        _ = try await V2ImportMatchingService().generateMatches(
          database: database,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func generateMatchCandidates() {
    guard let database else { return }
    Task {
      await perform {
        _ = try await V2ImportMatchingService().generateMatches(
          database: database,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func acceptMatch(_ candidate: MatchCandidateV2) {
    guard let database else { return }
    Task {
      await perform {
        try await database.markMatchCandidate(
          id: candidate.id,
          state: .accepted,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func rejectMatch(_ candidate: MatchCandidateV2) {
    guard let database else { return }
    Task {
      await perform {
        try await database.markMatchCandidate(
          id: candidate.id,
          state: .rejected,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func saveJournalTemplate(
    name: String,
    description: String,
    debitAccountID: UUID,
    creditAccountID: UUID,
    taxRate: TaxRate
  ) {
    guard let database else { return }
    Task {
      await perform {
        let now = self.clock.now()
        try await database.saveJournalTemplate(
          JournalTemplateV2(
            name: name,
            defaultDescription: description,
            debitAccountID: debitAccountID,
            creditAccountID: creditAccountID,
            taxRate: taxRate,
            invoiceStatus: .unknown,
            createdAt: now,
            updatedAt: now
          )
        )
        try await self.reload()
      }
    }
  }

  func saveRecurringJournal(
    templateID: UUID,
    amountYen: Int64,
    nextRunAt: Date
  ) {
    guard let database else { return }
    Task {
      await perform {
        let now = self.clock.now()
        try await database.saveRecurringJournal(
          RecurringJournalV2(
            templateID: templateID,
            frequency: .monthly,
            dayOfMonth: Calendar.current.component(.day, from: nextRunAt),
            amountYen: amountYen,
            nextRunAt: nextRunAt,
            createdAt: now,
            updatedAt: now
          )
        )
        try await self.reload()
      }
    }
  }

  func saveJournalRule(
    name: String,
    contains: String,
    debitAccountID: UUID,
    creditAccountID: UUID,
    taxRate: TaxRate
  ) {
    guard let database else { return }
    Task {
      await perform {
        let now = self.clock.now()
        try await database.saveJournalRule(
          JournalRuleV2(
            name: name,
            descriptionContains: contains,
            debitAccountID: debitAccountID,
            creditAccountID: creditAccountID,
            taxRate: taxRate,
            createdAt: now,
            updatedAt: now
          )
        )
        try await self.reload()
      }
    }
  }

  func generateRecurringCandidates() {
    guard let database else { return }
    Task {
      await perform {
        _ = try await GenerateRecurringCandidatesUseCase(repository: database)
          .execute(dueAt: self.clock.now())
        try await self.reload()
      }
    }
  }

  func confirmCandidate(_ candidate: JournalCandidateV2) {
    guard let database, let fiscalYear else { return }
    Task {
      await perform {
        let entry = try await ConfirmJournalCandidateUseCase(repository: database).execute(
          candidate: candidate,
          fiscalYear: fiscalYear,
          at: self.clock.now()
        )
        if let match = try await database.acceptedMatch(journalCandidateID: candidate.id) {
          try await database.linkEvidence(
            evidenceID: match.evidenceID,
            journalEntryID: entry.id,
            at: self.clock.now()
          )
          try await database.markImportCandidate(
            id: match.importCandidateID,
            state: .confirmed,
            at: self.clock.now()
          )
        }
        try await self.reload()
      }
    }
  }

  func rejectCandidate(_ candidate: JournalCandidateV2) {
    guard let database else { return }
    Task {
      await perform {
        try await database.markJournalCandidate(
          id: candidate.id,
          state: .rejected,
          journalEntryID: nil,
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func confirmAllCandidates() {
    guard let database, let fiscalYear else { return }
    let pending = journalCandidates
    Task {
      await perform {
        for candidate in pending {
          let entry = try await ConfirmJournalCandidateUseCase(repository: database).execute(
            candidate: candidate,
            fiscalYear: fiscalYear,
            at: self.clock.now()
          )
          if let match = try await database.acceptedMatch(journalCandidateID: candidate.id) {
            try await database.linkEvidence(
              evidenceID: match.evidenceID,
              journalEntryID: entry.id,
              at: self.clock.now()
            )
            try await database.markImportCandidate(
              id: match.importCandidateID,
              state: .confirmed,
              at: self.clock.now()
            )
          }
        }
        try await self.reload()
      }
    }
  }

  func saveCounterparty(code: String, displayName: String) {
    guard let database else { return }
    Task {
      await perform {
        let now = self.clock.now()
        try await database.saveCounterparty(
          Counterparty(
            metadata: EntityMetadata(createdAt: now),
            code: code,
            displayName: displayName,
            roles: [.customer, .vendor]
          )
        )
        try await self.reload()
      }
    }
  }

  func createInvoice(
    counterpartyID: UUID,
    number: String,
    subject: String,
    amountYen: Int64,
    dueDate: Date
  ) {
    guard let database, let fiscalYear, let profile else { return }
    Task {
      await perform {
        let now = self.clock.now()
        let invoice = try Invoice(
          metadata: EntityMetadata(createdAt: now),
          fiscalYearID: fiscalYear.id,
          counterpartyID: counterpartyID,
          number: number,
          issueDate: now,
          dueDate: dueDate,
          subject: subject,
          lines: [
            try InvoiceLine(
              description: subject,
              quantity: 1,
              unitPrice: Money(yen: amountYen),
              taxRate: .standard10
            )
          ],
          issuerName: profile.tradeName,
          issuerAddress: profile.taxAddress,
          issuerRegistrationStatus: profile.invoiceRegistrationStatus,
          issuerRegistrationNumber: profile.invoiceRegistrationNumber
        )
        try await database.saveInvoice(invoice)
        try await self.reload()
      }
    }
  }

  func issueInvoice(_ invoice: Invoice) {
    guard let database else { return }
    Task {
      await perform {
        try await database.issueInvoice(
          invoice,
          accounts: InvoiceIssueAccounts(
            receivableAccountID: try self.accountID(code: "1200"),
            revenueAccountID: try self.accountID(code: "4000")
          ),
          at: self.clock.now()
        )
        try await self.reload()
      }
    }
  }

  func settleInvoiceInFull(_ invoice: Invoice) {
    guard let database else { return }
    Task {
      await perform {
        let outstanding = try invoice.outstandingAmount()
        let now = self.clock.now()
        let settlement = try InvoiceSettlement(
          receivedAt: now,
          appliedAmount: outstanding,
          cashReceived: outstanding
        )
        try await database.settleInvoice(
          invoiceID: invoice.id,
          settlement: settlement,
          accounts: ReceivableSettlementAccounts(
            receivableAccountID: try self.accountID(code: "1200"),
            bankAccountID: try self.accountID(code: "1100"),
            bankFeeAccountID: try self.accountID(code: "5500"),
            withholdingAccountID: try self.accountID(code: "2000"),
            discountAccountID: try self.accountID(code: "3100"),
            overpaymentAccountID: try self.accountID(code: "3200")
          ),
          at: now
        )
        try await self.reload()
      }
    }
  }

  func saveClosingDecision(
    type: String,
    rationale: String,
    amountYen: Int64?,
    state: ClosingDecisionStateV2
  ) {
    guard let database, let fiscalYear else { return }
    Task {
      await perform {
        let now = self.clock.now()
        try await database.saveClosingDecision(
          ClosingDecisionV2(
            fiscalYearID: fiscalYear.id,
            decisionType: type,
            state: state,
            amountYen: amountYen,
            rationale: rationale,
            createdAt: now,
            updatedAt: now
          )
        )
        try await self.reload()
      }
    }
  }

  func runDiagnostics() {
    guard let database else { return }
    Task {
      await perform {
        self.diagnosticReport = try await database.diagnose(createdAt: self.clock.now())
      }
    }
  }

  func prepareRepairPlan(backupURL: URL) {
    guard let database, let diagnosticReport else { return }
    Task {
      repairPlan = await database.makeRepairPlan(
        from: diagnosticReport,
        backupURL: backupURL,
        createdAt: clock.now()
      )
    }
  }

  func prepareRepairWithBackup(passphrase: String) {
    guard let database, let diagnosticReport else { return }
    guard passphrase.count >= 12 else { return fail("修復前バックアップのパスフレーズは12文字以上にしてください。") }
    Task {
      await perform {
        let data = try await V2BackupService().makeBackup(
          database: database,
          passphrase: passphrase,
          createdAt: self.clock.now()
        )
        let filename = "before-repair-\(Int(self.clock.now().timeIntervalSince1970)).bpv2backup"
        let layout = await database.layout
        let backupURL = layout.backupsDirectory.appendingPathComponent(filename)
        try data.write(to: backupURL, options: .atomic)
        self.repairPlan = await database.makeRepairPlan(
          from: diagnosticReport,
          backupURL: backupURL,
          createdAt: self.clock.now()
        )
      }
    }
  }

  func applyRepairPlan() {
    guard let database, let plan = repairPlan else { return }
    Task {
      await perform {
        self.repairPlan = try await database.apply(plan, at: self.clock.now())
        self.diagnosticReport = try await database.diagnose(createdAt: self.clock.now())
        try await self.reload()
      }
    }
  }

  func makeEncryptedBackup(passphrase: String) async throws -> Data {
    guard let database else { throw V2WorkspaceError.databaseUnavailable }
    guard passphrase.count >= 12 else { throw V2WorkspaceError.weakPassphrase }
    let now = clock.now()
    let job = JobRecord(
      idempotencyKey: "backup:\(UUID().uuidString.lowercased())",
      kind: .backup,
      createdAt: now,
      updatedAt: now
    )
    try await database.enqueue(job)
    try await database.updateJob(
      id: job.id,
      state: .running,
      progressBasisPoints: 1_000,
      checkpoint: "snapshot-started",
      at: now
    )
    do {
      let data = try await V2BackupService().makeBackup(
        database: database,
        passphrase: passphrase,
        createdAt: now
      )
      try await database.updateJob(
        id: job.id,
        state: .succeeded,
        progressBasisPoints: 10_000,
        checkpoint: "encrypted-envelope-ready",
        at: clock.now()
      )
      jobs = try await database.jobs()
      return data
    } catch {
      try? await database.updateJob(
        id: job.id,
        state: .failed,
        progressBasisPoints: 1_000,
        checkpoint: "snapshot-started",
        failureReason: String(describing: error),
        at: clock.now()
      )
      jobs = (try? await database.jobs()) ?? jobs
      throw error
    }
  }

  func stageEncryptedRestore(from url: URL, passphrase: String) {
    guard let database else { return }
    guard passphrase.count >= 12 else { return fail("復元パスフレーズは12文字以上で入力してください。") }
    Task {
      await perform {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let payload = try V2BackupService().openBackup(data, passphrase: passphrase)
        let layout = await database.layout
        try V2RestoreCoordinator().stage(payload: payload, for: layout)
        self.restoreStatus = "復元データを検証して待機領域へ保存しました。アプリを終了して再起動すると切り替わります。現在のv2データは別フォルダへ退避されます。"
      }
    }
  }

  func checkForUpdates() {
    guard
      let manifestURL = URL(
        string:
          "https://github.com/Alshiel-1280/Blue-Print/releases/latest/download/update-manifest.json"
      )
    else { return }
    Task {
      await perform {
        let key = OfficialRulePackages.trustedReleaseKey
        let result = try await ManualUpdateService(
          manifestURL: manifestURL,
          currentVersion: BlueprintVersions.app,
          keyID: key.id,
          publicKey: key.rawRepresentation
        ).check()
        switch result {
        case .upToDate:
          self.updateStatus = "最新版です。"
        case .updateAvailable(let manifest):
          self.updateStatus =
            "v\(manifest.version)を利用できます。ダウンロード先：\(manifest.downloadURL.absoluteString)"
        }
      }
    }
  }

  func dismissError() { errorMessage = nil }

  private func open() async {
    defer { isLoading = false }
    do {
      let layout = try V2StorageLayout.applicationSupport()
      let preserved = try V2RestoreCoordinator().applyPendingRestoreIfNeeded(to: layout)
      if let preserved {
        restoreStatus = "復元を適用しました。復元前のv2データは \(preserved.path) に残しています。"
      }
      ruleStore = try OfficialRulePackages.makeStore(installedDirectory: layout.rulesDirectory)
      let database = try V2Database(layout: layout)
      self.database = database
      try await reload()
      try await resumePendingJobs()
    } catch {
      fail(Self.message(for: error))
    }
  }

  private func reload() async throws {
    guard let database else { throw V2WorkspaceError.databaseUnavailable }
    let snapshot = try await LoadV2WorkspaceUseCase(repository: database).execute()
    profile = snapshot.profile
    fiscalYear = snapshot.fiscalYear
    accounts = snapshot.accounts
    journalEntries = snapshot.journalEntries
    evidenceDocuments = try await database.evidenceDocuments()
    var candidates: [UUID: [OCRCandidate]] = [:]
    for document in evidenceDocuments {
      candidates[document.id] = try await database.ocrCandidates(evidenceID: document.id)
    }
    ocrCandidatesByEvidence = candidates
    journalTemplates = try await database.journalTemplates()
    journalRules = try await database.journalRules()
    recurringJournals = try await database.recurringJournals()
    journalCandidates = try await database.journalCandidates(state: .pending)
    importCandidates = try await database.importCandidates()
    matchCandidates = try await database.matchCandidates(state: .pending)
    counterparties = try await database.counterparties()
    invoices = try await database.invoices(fiscalYearID: fiscalYear?.id)
    auditEvents = try await database.auditEvents()
    if let fiscalYear {
      closingDecisions = try await database.closingDecisions(fiscalYearID: fiscalYear.id)
    } else {
      closingDecisions = []
    }
    jobs = try await database.jobs()
  }

  private func resumePendingJobs() async throws {
    guard let database else { return }
    for job in try await database.resumableJobs() {
      let message: String
      switch job.kind {
      case .ocr:
        message = "OCRを安全に再開するには証憑を選び直してください。保存済み原本は変更していません。"
      case .dataImport:
        message = "取込元ファイルへのアクセスを再許可して再開してください。"
      case .matching:
        message = "照合元を確認して再実行してください。候補は自動確定されません。"
      case .backup:
        message = "パスフレーズを再入力してバックアップを再実行してください。"
      case .xtxGeneration:
        message = "申告内容を再確認してXTX生成を再実行してください。"
      }
      try await database.updateJob(
        id: job.id,
        state: .failed,
        progressBasisPoints: job.progressBasisPoints,
        checkpoint: job.checkpoint ?? "interrupted",
        failureReason: message,
        at: clock.now()
      )
    }
    jobs = try await database.jobs()
  }

  private func accountID(code: String) throws -> UUID {
    guard let account = accounts.first(where: { $0.code == code }) else {
      throw RepositoryError.notFound
    }
    return account.id
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await operation()
      errorMessage = nil
    } catch {
      fail(Self.message(for: error))
    }
  }

  private func fail(_ message: String) {
    errorMessage = message
  }

  private static func message(for error: Error) -> String {
    switch error {
    case V2WorkspaceError.databaseUnavailable:
      return "v2データベースを開けません。保存先の権限と空き容量を確認してください。"
    case V2WorkspaceError.weakPassphrase:
      return "バックアップのパスフレーズは12文字以上にしてください。"
    case JournalError.dateOutsideFiscalYear:
      return "取引日は選択中の年度内にしてください。"
    case JournalError.debitsAndCreditsDoNotMatch:
      return "借方と貸方の金額が一致していません。"
    case RepositoryError.fiscalYearLocked:
      return "年度がロックされているため変更できません。"
    case BillingError.duplicateNumber:
      return "同じ請求番号が既に使われています。"
    case BillingError.missingQualifiedInvoiceField(let field):
      return "適格請求書の\(field)を入力してください。"
    case BillingError.invalidStateTransition:
      return "現在の請求状態ではこの操作を実行できません。"
    case BillingError.settlementExceedsOutstanding:
      return "入金額が請求残高を超えています。"
    case V2EvidenceServiceError.duplicate:
      return "同じSHA-256の証憑原本が既に保存されています。重複取込は行いませんでした。"
    case V2EvidenceServiceError.unsupportedFile:
      return "対応している証憑形式はPDFと主要な画像形式です。"
    default:
      return error.localizedDescription
    }
  }
}

enum V2WorkspaceError: Error {
  case databaseUnavailable
  case weakPassphrase
}

enum V2Destination: String, CaseIterable, Identifiable {
  case home
  case daily
  case books
  case closing
  case filing
  case utilities

  var id: Self { self }

  var title: String {
    switch self {
    case .home: "ホーム"
    case .daily: "日常処理"
    case .books: "帳簿"
    case .closing: "決算"
    case .filing: "申告"
    case .utilities: "データ管理"
    }
  }

  var symbol: String {
    switch self {
    case .home: "house"
    case .daily: "tray.full"
    case .books: "books.vertical"
    case .closing: "checkmark.seal"
    case .filing: "doc.text"
    case .utilities: "gearshape"
    }
  }
}
