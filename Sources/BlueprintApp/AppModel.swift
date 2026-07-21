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
  @Published private(set) var filingWorkspace: FilingWorkspace?
  @Published private(set) var wageStatements: [WageWithholdingStatement] = []
  @Published private(set) var filingProperties: [FilingProperty] = []
  @Published private(set) var rentalLedgerEntries: [RentalLedgerEntry] = []
  @Published private(set) var securitiesReports: [SecuritiesAnnualReport] = []
  @Published private(set) var stockLossCarryforwards: [StockLossCarryforward] = []
  @Published private(set) var otherIncomeEntries: [OtherIncomeEntry] = []
  @Published private(set) var filingDeductions: [FilingDeduction] = []
  @Published private(set) var unsupportedFilingCases: [UnsupportedFilingCase] = []
  @Published private(set) var eTaxExports: [ETaxExportRecord] = []
  @Published private(set) var yayoiMigrationPreview: YayoiMigrationBatch?
  @Published private(set) var diagnosticReport: DiagnosticReport?
  @Published private(set) var restorePreview: RestorePreview?
  @Published private(set) var automaticBackupEnabled = false
  @Published private(set) var isLoading = true
  @Published var errorMessage: String?

  private var database: BlueprintDatabase?
  private let clock: any BlueprintClock

  init(database: BlueprintDatabase? = nil, clock: any BlueprintClock = SystemClock()) {
    self.clock = clock
    do {
      self.database = try database ?? Self.makeDefaultDatabase()
      try reload()
      automaticBackupEnabled = UserDefaults.standard.bool(forKey: "automaticBackupEnabled")
      if automaticBackupEnabled { try? performAutomaticBackupIfNeeded() }
      #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BLUEPRINT_QA_YAYOI_FILE"],
          let data = FileManager.default.contents(atPath: path)
        {
          yayoiMigrationPreview = try YayoiCSVImporter.preview(
            data: data,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            product: .desktopOrOnline,
            availableAccounts: accounts,
            importedAt: clock.now()
          )
        }
      #endif
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
      let configuredRules = try? OfficialRules2025.catalog.rules(for: calendarYear)
      let fiscalYear = try FiscalYear(
        metadata: EntityMetadata(createdAt: now),
        calendarYear: calendarYear,
        taxRuleSetID: configuredRules?.0.id ?? "tax-\(calendarYear)-unavailable",
        formRuleSetID: configuredRules?.1.id ?? "form-\(calendarYear)-unavailable"
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

  func saveWageStatement(
    payerName: String,
    paymentAmount: Int64,
    withholdingTax: Int64,
    socialInsurance: Int64,
    evidenceDocumentID: EntityID?
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let wage = try WageWithholdingStatement(
        fiscalYearID: fiscalYear.id,
        payerName: payerName,
        paymentAmount: Money(yen: paymentAmount),
        withholdingTax: Money(yen: withholdingTax),
        socialInsurance: Money(yen: socialInsurance),
        evidenceDocumentID: evidenceDocumentID,
        reviewState: evidenceDocumentID == nil ? .unconfirmed : .confirmed
      )
      try database.saveWageStatement(
        wage,
        attachment: filingAttachment(
          evidenceDocumentID, title: "源泉徴収票 \(payerName)", category: "給与"),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveFilingProperty(name: String, address: String, tenantName: String) {
    guard let database, let fiscalYear else { return }
    do {
      try database.filing.saveProperty(
        FilingProperty(
          fiscalYearID: fiscalYear.id, name: name, address: address, tenantName: tenantName))
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveRentalEntry(
    propertyID: EntityID?,
    transactionDate: Date,
    kind: RentalLedgerEntryKind,
    description: String,
    amount: Int64,
    evidenceDocumentID: EntityID?
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let entry = try RentalLedgerEntry(
        fiscalYearID: fiscalYear.id,
        propertyID: propertyID,
        transactionDate: transactionDate,
        kind: kind,
        description: description,
        amount: Money(yen: amount),
        evidenceDocumentID: evidenceDocumentID
      )
      try database.saveRentalLedgerEntry(
        entry,
        attachment: filingAttachment(evidenceDocumentID, title: description, category: "不動産"),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveSecuritiesReport(
    brokerName: String,
    accountName: String,
    withholdingKind: SecuritiesWithholdingKind,
    proceeds: Int64,
    acquisitionCost: Int64,
    nationalTax: Int64,
    localTax: Int64,
    dividend: Int64,
    dividendTax: Int64,
    evidenceDocumentID: EntityID?
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let report = try SecuritiesAnnualReport(
        fiscalYearID: fiscalYear.id,
        brokerName: brokerName,
        accountName: accountName,
        withholdingKind: withholdingKind,
        proceeds: Money(yen: proceeds),
        acquisitionCost: Money(yen: acquisitionCost),
        nationalWithholdingTax: Money(yen: nationalTax),
        localWithholdingTax: Money(yen: localTax),
        dividendAmount: Money(yen: dividend),
        dividendWithholdingTax: Money(yen: dividendTax),
        evidenceDocumentID: evidenceDocumentID
      )
      try database.saveSecuritiesAnnualReport(
        report,
        attachment: filingAttachment(
          evidenceDocumentID, title: "年間取引報告書 \(brokerName)", category: "株式"),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveStockLossCarryforward(
    sourceYear: Int, broughtForward: Int64, currentLoss: Int64, utilized: Int64
  ) {
    guard let database, let fiscalYear else { return }
    do {
      try database.filing.saveLossCarryforward(
        StockLossCarryforward(
          fiscalYearID: fiscalYear.id,
          sourceYear: sourceYear,
          broughtForward: Money(yen: broughtForward),
          currentYearLoss: Money(yen: currentLoss),
          utilized: Money(yen: utilized)
        ))
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveOtherIncome(
    kind: OtherIncomeKind,
    title: String,
    revenue: Int64,
    expenses: Int64,
    withholdingTax: Int64,
    evidenceDocumentID: EntityID?
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let income = try OtherIncomeEntry(
        fiscalYearID: fiscalYear.id,
        kind: kind,
        title: title,
        revenue: Money(yen: revenue),
        expenses: Money(yen: expenses),
        withholdingTax: Money(yen: withholdingTax),
        evidenceDocumentID: evidenceDocumentID
      )
      try database.saveOtherIncomeEntry(
        income,
        attachment: filingAttachment(evidenceDocumentID, title: title, category: "その他所得"),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveFilingDeduction(
    kind: DeductionKind, title: String, amount: Int64, evidenceDocumentID: EntityID?
  ) {
    guard let database, let fiscalYear else { return }
    do {
      let deduction = try FilingDeduction(
        fiscalYearID: fiscalYear.id,
        kind: kind,
        title: title,
        amount: Money(yen: amount),
        evidenceDocumentID: evidenceDocumentID
      )
      try database.saveFilingDeduction(
        deduction,
        attachment: filingAttachment(evidenceDocumentID, title: title, category: "所得控除"),
        at: clock.now()
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveUnsupportedFilingCase(title: String, guidance: String) {
    guard let database, let fiscalYear else { return }
    do {
      try database.filing.saveUnsupportedCase(
        UnsupportedFilingCase(
          fiscalYearID: fiscalYear.id, title: title, guidance: guidance))
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func generateETaxPackage() -> ETaxGeneratedPackage? {
    guard let data = eTaxReturnData, let blueReturnPackage else {
      errorMessage = "対象年度の申告データを生成できません。事業者設定と決算結果を確認してください。"
      return nil
    }
    do {
      let issues = ETaxValidator.validate(
        data, rules: try currentRules().1, blueReturn: blueReturnPackage)
      let package = try XTXGenerator.generate(data, validationIssues: issues)
      errorMessage = nil
      return package
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
      return nil
    }
  }

  func recordETaxExport(_ package: ETaxGeneratedPackage) {
    guard let database, let fiscalYear, let data = eTaxReturnData else { return }
    do {
      let now = clock.now()
      try database.saveETaxExport(
        ETaxExportRecord(
          fiscalYearID: fiscalYear.id,
          exportedAt: now,
          fileName: package.fileName,
          fileHash: package.hash,
          taxRuleSetID: data.taxRuleSetID,
          formRuleSetID: data.formRuleSetID,
          schemaVersion: data.procedureVersion,
          ledgerFingerprint: data.ledgerFingerprint,
          checklist: data.checklist
        ),
        at: now
      )
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func attachETaxReceipt(from url: URL) {
    guard let database, let fiscalYear else { return }
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let now = clock.now()
      let document = try database.importEvidence(
        from: url,
        mimeType: Self.mimeType(for: url),
        origin: .electronicTransaction,
        at: now
      )
      var workspace =
        filingWorkspace
        ?? FilingWorkspace(metadata: EntityMetadata(createdAt: now), fiscalYearID: fiscalYear.id)
      workspace.attach(
        FilingAttachment(
          evidenceDocumentID: document.id,
          title: url.deletingPathExtension().lastPathComponent,
          category: "e-Tax受付・申告控え"
        ),
        at: now
      )
      try database.filing.saveWorkspace(workspace)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  var propertyIncomeReport: PropertyIncomeReport {
    PropertyIncomeReport.make(entries: rentalLedgerEntries)
  }

  var blueReturnPackage: BlueReturnPackage? {
    guard let fiscalYear, let profile, let annualProfitAndLoss, let annualBalanceSheet else {
      return nil
    }
    return BlueReturnMapper.make(
      fiscalYear: fiscalYear.calendarYear,
      profile: profile,
      profitAndLoss: annualProfitAndLoss,
      balanceSheet: annualBalanceSheet,
      businessSnapshot: BusinessIncomeSnapshot(
        revenue: annualProfitAndLoss.totalRevenue,
        expenses: annualProfitAndLoss.totalExpenses,
        income: annualProfitAndLoss.profit,
        generatedAt: clock.now()
      ),
      propertyReport: propertyIncomeReport
    )
  }

  var blueReturnDeductionAssessment: BlueReturnDeductionAssessment? {
    guard let profile, let annualBalanceSheet, let rules = try? currentRules() else { return nil }
    return BlueReturnMapper.deductionAssessment(
      profile: profile,
      balanceSheet: annualBalanceSheet,
      taxRuleSet: rules.0,
      intendsElectronicFiling: true
    )
  }

  var eTaxReturnData: ETaxReturnData? {
    guard let fiscalYear, let profile, let blueReturnPackage,
      let blueReturnDeductionAssessment, let filingSummary,
      let rules = try? currentRules()
    else { return nil }
    return ETaxMapper.make(
      fiscalYear: fiscalYear.calendarYear,
      profile: profile,
      blueReturn: blueReturnPackage,
      deductionAssessment: blueReturnDeductionAssessment,
      filingSummary: filingSummary,
      deductions: filingDeductions,
      unsupportedCases: unsupportedFilingCases,
      taxRuleSet: rules.0,
      formRuleSet: rules.1,
      ledgerFingerprint: currentLedgerFingerprint
    )
  }

  var eTaxValidationIssues: [ETaxValidationIssue] {
    guard let data = eTaxReturnData, let blueReturnPackage, let rules = try? currentRules() else {
      return [
        ETaxValidationIssue(
          fieldTag: nil,
          message: "この年度の税務・e-Taxルールはまだ登録されていません。",
          severity: .error
        )
      ]
    }
    return ETaxValidator.validate(data, rules: rules.1, blueReturn: blueReturnPackage)
  }

  var eTaxNeedsRegeneration: Bool {
    eTaxExports.first?.needsRegeneration(currentLedgerFingerprint: currentLedgerFingerprint)
      ?? false
  }

  var currentFormRuleSet: FormRuleSet? { try? currentRules().1 }

  private var currentLedgerFingerprint: String {
    XTXGenerator.ledgerFingerprint(parts: [
      journalEntries.map { "\($0.id)|\($0.metadata.updatedAt.timeIntervalSince1970)" }.joined(),
      rentalLedgerEntries.map { "\($0.id)|\($0.amount.yen)" }.joined(),
      wageStatements.map { "\($0.id)|\($0.paymentAmount.yen)" }.joined(),
      securitiesReports.map { "\($0.id)|\($0.proceeds.yen)|\($0.acquisitionCost.yen)" }.joined(),
      filingDeductions.map { "\($0.id)|\($0.amount.yen)" }.joined(),
    ])
  }

  private func currentRules() throws -> (TaxRuleSet, FormRuleSet) {
    guard let fiscalYear else { throw RuleSetError.unsupportedYear(0) }
    return try OfficialRules2025.catalog.rules(for: fiscalYear.calendarYear)
  }

  var filingSummary: FilingWorkspaceSummary? {
    guard let fiscalYear, let filingWorkspace, let annualProfitAndLoss else { return nil }
    return try? FilingAggregation.summary(
      fiscalYearID: fiscalYear.id,
      businessIncome: BusinessIncomeSnapshot(
        revenue: annualProfitAndLoss.totalRevenue,
        expenses: annualProfitAndLoss.totalExpenses,
        income: annualProfitAndLoss.profit,
        generatedAt: clock.now()
      ),
      workspace: filingWorkspace,
      wages: wageStatements,
      rentalEntries: rentalLedgerEntries,
      securitiesReports: securitiesReports,
      otherIncome: otherIncomeEntries,
      deductions: filingDeductions,
      unsupportedCases: unsupportedFilingCases
    )
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

  func previewYayoiMigration(data: Data, filename: String, product: YayoiProduct) {
    do {
      yayoiMigrationPreview = try YayoiCSVImporter.preview(
        data: data,
        filename: filename,
        product: product,
        availableAccounts: accounts,
        importedAt: clock.now()
      )
      errorMessage = nil
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func updateYayoiMapping(sourceAccount: String, targetAccountID: EntityID?) {
    guard var preview = yayoiMigrationPreview,
      let index = preview.accountMappings.firstIndex(where: { $0.sourceAccount == sourceAccount })
    else { return }
    preview.accountMappings[index].targetAccountID = targetAccountID
    preview.accountMappings[index].targetAccountName =
      accounts.first {
        $0.id == targetAccountID
      }?.name
    yayoiMigrationPreview = preview
  }

  func cancelYayoiMigration() {
    guard var preview = yayoiMigrationPreview else { return }
    preview.cancel()
    yayoiMigrationPreview = preview
  }

  func commitYayoiMigration() {
    guard let database, let fiscalYear, let preview = yayoiMigrationPreview else { return }
    do {
      try database.importYayoiMigration(preview, fiscalYearID: fiscalYear.id, at: clock.now())
      try? performAutomaticBackupIfNeeded(force: true)
      yayoiMigrationPreview = nil
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func portableArchiveData() -> Data? {
    guard let service = portableDataService() else { return nil }
    do {
      let data = try service.encodeArchive(service.makeArchive(createdAt: clock.now()))
      errorMessage = nil
      return data
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
      return nil
    }
  }

  func encryptedBackupData(passphrase: String) -> Data? {
    guard let service = portableDataService() else { return nil }
    guard passphrase.count >= 12 else {
      errorMessage = "パスフレーズが短いためバックアップを作成できません。12文字以上で入力してください。"
      return nil
    }
    do {
      let data = try service.makeEncryptedBackup(passphrase: passphrase, createdAt: clock.now())
      errorMessage = nil
      return data
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
      return nil
    }
  }

  func enableAutomaticBackups(passphrase: String) {
    guard passphrase.count >= 12 else {
      errorMessage = "パスフレーズが短いため自動バックアップを有効にできません。12文字以上で入力してください。"
      return
    }
    do {
      try BackupCredentialStore().save(passphrase)
      UserDefaults.standard.set(true, forKey: "automaticBackupEnabled")
      automaticBackupEnabled = true
      try performAutomaticBackupIfNeeded(force: true)
      errorMessage = nil
    } catch {
      errorMessage = "自動バックアップを有効にできません。キーチェーンへの保存権限を確認してください。"
    }
  }

  func disableAutomaticBackups() {
    do {
      try BackupCredentialStore().remove()
      UserDefaults.standard.set(false, forKey: "automaticBackupEnabled")
      automaticBackupEnabled = false
      errorMessage = nil
    } catch {
      errorMessage = "自動バックアップ設定を解除できません。キーチェーンの状態を確認してください。"
    }
  }

  func inspectEncryptedBackup(data: Data, passphrase: String) {
    guard let service = portableDataService() else { return }
    do {
      let archive = try service.openEncryptedBackup(data, passphrase: passphrase)
      pendingRestoreArchive = archive
      restorePreview = service.previewRestore(archive)
      errorMessage = nil
    } catch {
      pendingRestoreArchive = nil
      restorePreview = nil
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func stageInspectedRestore() {
    guard let service = portableDataService(), let archive = pendingRestoreArchive else { return }
    do {
      let pending = service.root.appendingPathComponent("RestorePending", isDirectory: true)
      if FileManager.default.fileExists(atPath: pending.path) {
        try FileManager.default.removeItem(at: pending)
      }
      try service.restore(archive, to: pending)
      try Data("pending".utf8).write(
        to: service.root.appendingPathComponent("restore-on-next-launch"), options: .atomic)
      errorMessage = nil
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func runDataDiagnostics() {
    guard let service = portableDataService() else { return }
    do {
      diagnosticReport = try service.diagnose(createdAt: clock.now())
      errorMessage = nil
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
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
      if let stored = try database.filing.workspace(fiscalYearID: fiscalYear.id) {
        filingWorkspace = stored
      } else {
        let workspace = FilingWorkspace(
          metadata: EntityMetadata(createdAt: clock.now()), fiscalYearID: fiscalYear.id)
        try database.filing.saveWorkspace(workspace)
        filingWorkspace = workspace
      }
      wageStatements = try database.filing.wages(fiscalYearID: fiscalYear.id)
      filingProperties = try database.filing.properties(fiscalYearID: fiscalYear.id)
      rentalLedgerEntries = try database.filing.rentalEntries(fiscalYearID: fiscalYear.id)
      securitiesReports = try database.filing.securitiesReports(fiscalYearID: fiscalYear.id)
      stockLossCarryforwards = try database.filing.lossCarryforwards(fiscalYearID: fiscalYear.id)
      otherIncomeEntries = try database.filing.otherIncome(fiscalYearID: fiscalYear.id)
      filingDeductions = try database.filing.deductions(fiscalYearID: fiscalYear.id)
      unsupportedFilingCases = try database.filing.unsupportedCases(fiscalYearID: fiscalYear.id)
      eTaxExports = try database.eTax.exports(fiscalYearID: fiscalYear.id)
    } else {
      fixedAssets = []
      closingChecklist = ClosingChecklist(items: [])
      filingWorkspace = nil
      wageStatements = []
      filingProperties = []
      rentalLedgerEntries = []
      securitiesReports = []
      stockLossCarryforwards = []
      otherIncomeEntries = []
      filingDeductions = []
      unsupportedFilingCases = []
      eTaxExports = []
    }
  }

  private var pendingRestoreArchive: PortableArchive?

  private func portableDataService() -> PortableDataService? {
    guard let database else { return nil }
    let root = database.connection.databaseURL.deletingLastPathComponent()
      .deletingLastPathComponent()
    return PortableDataService(connection: database.connection, root: root)
  }

  private func performAutomaticBackupIfNeeded(force: Bool = false) throws {
    guard automaticBackupEnabled,
      let passphrase = try BackupCredentialStore().load(),
      let service = portableDataService()
    else { return }
    let calendar = Calendar(identifier: .gregorian)
    if !force,
      let last = UserDefaults.standard.object(forKey: "automaticBackupLastRun") as? Date,
      calendar.isDate(last, inSameDayAs: clock.now())
    {
      return
    }
    let directory = service.root.appendingPathComponent("Backups/Automatic", isDirectory: true)
    _ = try service.writeAutomaticBackup(
      passphrase: passphrase,
      directory: directory,
      retainGenerations: 7,
      createdAt: clock.now()
    )
    UserDefaults.standard.set(clock.now(), forKey: "automaticBackupLastRun")
  }

  private func filingAttachment(
    _ evidenceDocumentID: EntityID?,
    title: String,
    category: String
  ) -> FilingAttachment? {
    evidenceDocumentID.map {
      FilingAttachment(evidenceDocumentID: $0, title: title, category: category)
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
    case RuleSetError.unsupportedYear(let year):
      "\(year)年分の税務・e-Taxルールは未対応です。対応年度を確認してください。"
    case YayoiMigrationError.unmappedAccount(let account):
      "弥生の勘定科目「\(account)」に取込先がありません。科目マッピングを設定してください。"
    case YayoiMigrationError.cancelledBatch:
      "取消済みの移行プレビューは取り込めません。CSVをもう一度選択してください。"
    case PortableDataError.authenticationFailed:
      "バックアップを開けません。パスフレーズが正しいか確認してください。"
    case PortableDataError.incompatibleVersion(let found, let supported):
      "バックアップ形式 \(found) は、このアプリの対応形式 \(supported) より新しいため復元できません。"
    case PortableDataError.evidenceHashMismatch(let path):
      "証憑原本のハッシュが一致しません。復元を中止しました: \(path)"
    case XTXGenerationError.validationFailed(let issues):
      "e-Tax出力前の検証で\(issues.count)件のエラーが見つかりました。申告ワークスペースで修正してください。"
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
    case FilingError.invalidAmount:
      "申告資料の金額は0円以上で入力してください。"
    case FilingError.invalidLossCarryforward:
      "損失の利用額が繰越可能額を超えています。前年繰越・当年損失・利用額を確認してください。"
    case FilingError.missingName:
      "支払者、物件、証券会社または資料名を入力してください。"
    default:
      "保存処理を完了できませんでした。入力内容と保存先の空き容量を確認し、もう一度実行してください。"
    }
  }

  private static func makeDefaultDatabase() throws -> BlueprintDatabase {
    #if DEBUG
      if let root = ProcessInfo.processInfo.environment["BLUEPRINT_DATA_ROOT"], !root.isEmpty {
        let layout = StorageLayout(root: URL(fileURLWithPath: root, isDirectory: true))
        try layout.applyPendingRestoreIfNeeded()
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
