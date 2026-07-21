import BlueprintAudit
import BlueprintBilling
import BlueprintClosing
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
  @Published private(set) var counterparties: [Counterparty] = []
  @Published private(set) var invoices: [Invoice] = []
  @Published private(set) var vendorBills: [VendorBill] = []
  @Published private(set) var fixedAssets: [FixedAsset] = []
  @Published private(set) var closingChecklist = ClosingChecklist(items: [])
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

  func createInvoice(
    customerName: String,
    number: String,
    issueDate: Date,
    dueDate: Date,
    subject: String,
    lineDescription: String,
    netAmount: Int64,
    taxRate: TaxRate
  ) {
    guard let database, let fiscalYear, let profile else { return }
    do {
      let now = clock.now()
      let normalizedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedName.isEmpty, netAmount > 0 else { throw BillingError.invalidAmount }
      let counterparty =
        counterparties.first {
          $0.roles.contains(.customer) && $0.displayName == normalizedName
        }
        ?? Counterparty(
          metadata: EntityMetadata(createdAt: now),
          code: "C-\(String(format: "%04d", counterparties.count + 1))",
          displayName: normalizedName,
          roles: [.customer]
        )
      if !counterparties.contains(where: { $0.id == counterparty.id }) {
        try database.saveCounterparty(counterparty, at: now)
      }
      let proposedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedNumber =
        proposedNumber.isEmpty
        ? InvoiceNumbering.next(
          calendarYear: fiscalYear.calendarYear,
          existingNumbers: invoices.map(\.number)
        )
        : proposedNumber
      let invoice = try Invoice(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: fiscalYear.id,
        counterpartyID: counterparty.id,
        number: resolvedNumber,
        issueDate: issueDate,
        dueDate: dueDate,
        subject: subject,
        lines: [
          try InvoiceLine(
            description: lineDescription,
            quantity: 1,
            unitPrice: Money(yen: netAmount),
            taxRate: taxRate
          )
        ],
        roundingRule: profile.roundingRule,
        issuerName: profile.tradeName,
        issuerAddress: profile.postalAddress,
        issuerRegistrationStatus: profile.invoiceRegistrationStatus,
        issuerRegistrationNumber: profile.invoiceRegistrationNumber
      )
      _ = try database.issueInvoice(
        invoice,
        accounts: InvoiceIssueAccounts(
          receivableAccountID: try accountID(code: "1200"),
          revenueAccountID: try accountID(code: "4000")
        ),
        at: now
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func recordInvoicePayment(
    _ invoice: Invoice,
    appliedAmount: Int64,
    bankFee: Int64,
    withholdingTax: Int64,
    discount: Int64
  ) {
    guard let database else { return }
    do {
      let deductions = bankFee + withholdingTax + discount
      let settlement = try InvoiceSettlement(
        receivedAt: clock.now(),
        appliedAmount: Money(yen: appliedAmount),
        cashReceived: Money(yen: appliedAmount - deductions),
        bankFee: Money(yen: bankFee),
        withholdingTax: Money(yen: withholdingTax),
        discount: Money(yen: discount)
      )
      _ = try database.settleInvoice(
        invoiceID: invoice.id,
        settlement: settlement,
        accounts: ReceivableSettlementAccounts(
          receivableAccountID: try accountID(code: "1200"),
          bankAccountID: try accountID(code: "1100"),
          bankFeeAccountID: try accountID(code: "5500"),
          withholdingAccountID: try accountID(code: "2000"),
          discountAccountID: try accountID(code: "3100"),
          overpaymentAccountID: try accountID(code: "3200")
        ),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func cancelInvoice(_ invoice: Invoice, reason: String) {
    guard let database else { return }
    do {
      _ = try database.cancelInvoice(id: invoice.id, reason: reason, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func reissueInvoice(_ invoice: Invoice, reason: String) {
    guard let database else { return }
    do {
      _ = try database.reissueInvoice(id: invoice.id, reason: reason, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func createVendorBill(
    vendorName: String,
    referenceNumber: String,
    issueDate: Date,
    dueDate: Date,
    description: String,
    netAmount: Int64,
    withholdingEnabled: Bool,
    withholdingTax: Int64
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let now = clock.now()
      let normalizedName = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedName.isEmpty, netAmount > 0 else { throw BillingError.invalidAmount }
      let vendor =
        counterparties.first {
          $0.roles.contains(.vendor) && $0.displayName == normalizedName
        }
        ?? Counterparty(
          metadata: EntityMetadata(createdAt: now),
          code: "V-\(String(format: "%04d", counterparties.count + 1))",
          displayName: normalizedName,
          roles: [.vendor],
          withholdingDefaultEnabled: false
        )
      if !counterparties.contains(where: { $0.id == vendor.id }) {
        try database.saveCounterparty(vendor, at: now)
      }
      let bill = try VendorBill(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: fiscalYear.id,
        vendorID: vendor.id,
        referenceNumber: referenceNumber,
        issueDate: issueDate,
        dueDate: dueDate,
        description: description,
        lines: [
          try InvoiceLine(
            description: description,
            quantity: 1,
            unitPrice: Money(yen: netAmount),
            taxRate: .standard10
          )
        ],
        invoiceStatus: vendor.invoiceRegistrationStatus,
        withholdingEnabled: withholdingEnabled,
        withholdingTax: Money(yen: withholdingTax)
      )
      _ = try database.confirmVendorBill(
        bill,
        accounts: VendorBillAccounts(
          expenseAccountID: try accountID(code: "5100"),
          payableAccountID: try accountID(code: "2100")
        ),
        at: now
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func recordVendorPayment(_ bill: VendorBill, appliedAmount: Int64) {
    guard let database else { return }
    do {
      let withholding = min(bill.withholdingTax.yen, appliedAmount)
      let payment = try VendorBillPayment(
        paidAt: clock.now(),
        appliedAmount: Money(yen: appliedAmount),
        cashPaid: Money(yen: appliedAmount - withholding),
        withholdingTax: Money(yen: withholding)
      )
      _ = try database.settleVendorBill(
        billID: bill.id,
        payment: payment,
        accounts: VendorPaymentAccounts(
          payableAccountID: try accountID(code: "2100"),
          bankAccountID: try accountID(code: "1100"),
          bankFeeAccountID: try accountID(code: "5500"),
          withholdingAccountID: try accountID(code: "2000")
        ),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveFixedAsset(
    code: String,
    name: String,
    category: String,
    acquisitionDate: Date,
    serviceDate: Date,
    cost: Int64,
    usefulLifeYears: Int,
    method: DepreciationMethod,
    businessUseBasisPoints: Int,
    assetAccountID: EntityID,
    depreciationExpenseAccountID: EntityID,
    accumulatedDepreciationAccountID: EntityID
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let asset = try FixedAsset(
        metadata: EntityMetadata(createdAt: clock.now()),
        fiscalYearID: fiscalYear.id,
        code: code,
        name: name,
        category: category,
        acquisitionDate: acquisitionDate,
        serviceDate: serviceDate,
        acquisitionCost: Money(yen: cost),
        usefulLifeYears: usefulLifeYears,
        method: method,
        decliningRateBasisPoints: method == .decliningBalance ? 2_000 : 0,
        businessUseBasisPoints: businessUseBasisPoints,
        assetAccountID: assetAccountID,
        depreciationExpenseAccountID: depreciationExpenseAccountID,
        accumulatedDepreciationAccountID: accumulatedDepreciationAccountID
      )
      try database.saveFixedAsset(asset, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func postDepreciation(_ asset: FixedAsset) {
    guard let database, let fiscalYear else { return }
    do {
      _ = try database.postDepreciation(
        assetID: asset.id,
        calendarYear: fiscalYear.calendarYear,
        at: fiscalYearEnd
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveInventory(opening: Int64, purchases: Int64, closing: Int64) {
    guard let database else { return }
    do {
      let inventory = try InventoryClosing(
        openingInventory: Money(yen: opening),
        purchases: Money(yen: purchases),
        closingInventory: Money(yen: closing)
      )
      try database.saveInventoryClosing(inventory, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveHouseholdRule(
    name: String,
    expenseAccountID: EntityID,
    ownerDrawingsAccountID: EntityID,
    personalBasisPoints: Int,
    rationale: String
  ) {
    guard let database else { return }
    do {
      let rule = try HouseholdAllocationRule(
        name: name,
        expenseAccountID: expenseAccountID,
        ownerDrawingsAccountID: ownerDrawingsAccountID,
        personalBasisPoints: personalBasisPoints,
        rationale: rationale
      )
      try database.saveHouseholdRule(rule, at: clock.now())
      _ = try database.postHouseholdAllocation(ruleID: rule.id, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func profitAndLoss(period: ClosedRange<Date>) -> ProfitAndLossReport? {
    try? ClosingReports.profitAndLoss(
      entries: journalEntries,
      accounts: accounts,
      period: period
    )
  }

  var annualProfitAndLoss: ProfitAndLossReport? {
    guard let period = fiscalYearPeriod else { return nil }
    return profitAndLoss(period: period)
  }

  var annualBalanceSheet: BalanceSheetReport? {
    guard let period = fiscalYearPeriod else { return nil }
    return try? ClosingReports.balanceSheet(
      entries: journalEntries,
      accounts: accounts,
      fiscalYearPeriod: period,
      asOf: period.upperBound
    )
  }

  func balanceSheet(asOf date: Date) -> BalanceSheetReport? {
    guard let period = fiscalYearPeriod else { return nil }
    return try? ClosingReports.balanceSheet(
      entries: journalEntries,
      accounts: accounts,
      fiscalYearPeriod: period,
      asOf: min(date, period.upperBound)
    )
  }

  var taxClassificationBalances: [TaxClassificationBalance] {
    (try? AccountingReports.taxClassificationBalances(entries: journalEntries)) ?? []
  }

  var receivableAging: [AgingAmount] {
    (try? ClosingReports.receivableAging(
      invoices: invoices,
      counterparties: counterparties,
      asOf: clock.now()
    )) ?? []
  }

  var payableAging: [AgingAmount] {
    (try? ClosingReports.payableAging(
      bills: vendorBills,
      counterparties: counterparties,
      asOf: clock.now()
    )) ?? []
  }

  func financialStatementsPDF() -> Data? {
    guard let annualProfitAndLoss, let annualBalanceSheet, let profile, let fiscalYear else {
      return nil
    }
    return try? ClosingReportExporter.financialStatementsPDF(
      profitAndLoss: annualProfitAndLoss,
      balanceSheet: annualBalanceSheet,
      profileName: profile.tradeName,
      fiscalYear: fiscalYear
    )
  }

  func financialStatementsCSV() -> Data? {
    guard let annualProfitAndLoss, let annualBalanceSheet, let fiscalYear else { return nil }
    return ClosingReportExporter.financialStatementsCSV(
      profitAndLoss: annualProfitAndLoss,
      balanceSheet: annualBalanceSheet,
      fiscalYear: fiscalYear
    )
  }

  func journalExportPDF() -> Data? {
    guard let profile, let fiscalYear else { return nil }
    return try? ClosingReportExporter.journalPDF(
      entries: journalEntries,
      accounts: accounts,
      profileName: profile.tradeName,
      fiscalYear: fiscalYear
    )
  }

  func journalExportCSV() -> Data? {
    guard let fiscalYear else { return nil }
    return ClosingReportExporter.journalCSV(
      entries: journalEntries,
      accounts: accounts,
      fiscalYear: fiscalYear
    )
  }

  func fixedAssetLedgerCSV() -> Data? {
    guard let fiscalYear else { return nil }
    return try? ClosingReportExporter.fixedAssetLedgerCSV(
      assets: fixedAssets,
      through: fiscalYear.calendarYear
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
    counterparties = try database.billing.counterparties(includeInactive: false)
    invoices = try database.billing.invoices(
      BillingSearch(fiscalYearID: fiscalYear?.id)
    )
    vendorBills = try database.billing.vendorBills(
      BillingSearch(fiscalYearID: fiscalYear?.id)
    )
    if let fiscalYear {
      fixedAssets = try database.closing.assets(fiscalYearID: fiscalYear.id)
      closingChecklist = try database.closingChecklist(asOf: clock.now())
    } else {
      fixedAssets = []
      closingChecklist = ClosingChecklist(items: [])
    }
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
    case BillingError.duplicateNumber:
      "同じ請求番号が既にあります。請求番号を変更してください。"
    case BillingError.missingQualifiedInvoiceField(let field):
      "適格請求書の必須項目「\(field)」が未入力です。事業者設定または請求内容を確認してください。"
    case BillingError.invalidStateTransition:
      "現在の状態ではこの操作を実行できません。入金・取消状況を確認してください。"
    case BillingError.settlementExceedsOutstanding:
      "消込額が未収・未払残高を超えています。金額を修正してください。"
    case BillingError.settlementComponentsDoNotBalance:
      "入出金額と手数料・源泉税・値引の合計が一致していません。"
    case FixedAssetError.invalidCost:
      "取得価額は1円以上で入力してください。"
    case FixedAssetError.invalidUsefulLife:
      "耐用年数は1年以上で入力してください。"
    case ClosingAdjustmentError.invalidRate:
      "事業割合・家事割合は0%から100%の範囲で入力してください。"
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

  private func accountID(code: String) throws -> EntityID {
    guard let account = accounts.first(where: { $0.code == code }) else {
      throw RepositoryError.notFound
    }
    return account.id
  }

  private var fiscalYearPeriod: ClosedRange<Date>? {
    guard let fiscalYear else { return nil }
    let calendar = Calendar(identifier: .gregorian)
    guard
      let start = calendar.date(
        from: DateComponents(year: fiscalYear.calendarYear, month: 1, day: 1)
      ),
      let end = calendar.date(
        from: DateComponents(
          year: fiscalYear.calendarYear,
          month: 12,
          day: 31,
          hour: 23,
          minute: 59,
          second: 59
        ))
    else { return nil }
    return start...end
  }

  private var fiscalYearEnd: Date {
    fiscalYearPeriod?.upperBound ?? clock.now()
  }
}
