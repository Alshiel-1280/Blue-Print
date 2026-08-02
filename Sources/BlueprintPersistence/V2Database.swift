import BlueprintAudit
import BlueprintBilling
import BlueprintDocuments
import BlueprintDomain
import BlueprintTransfer
import CryptoKit
import Foundation

public actor V2Database {
  public static let schemaVersion = 1

  public let layout: V2StorageLayout
  private let connection: SQLiteConnection

  public init(
    layout: V2StorageLayout,
    fileManager: FileManager = .default
  ) throws {
    try layout.prepare(fileManager: fileManager)
    self.layout = layout
    connection = try SQLiteConnection(databaseURL: layout.databaseURL)
    try Self.createSchemaIfNeeded(connection)
    try connection.enableWriteAheadLogging()
  }

  public func tableNames() throws -> [String] {
    try connection.query(
      """
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
      ORDER BY name
      """
    ).compactMap { $0["name"]?.string }
  }

  public func userVersion() throws -> Int {
    Int(try connection.scalarInt("PRAGMA user_version") ?? 0)
  }

  public func databaseSnapshot() throws -> Data {
    try connection.checkpoint()
    return try Data(contentsOf: layout.databaseURL)
  }

  public func columns(in table: String) throws -> [String] {
    guard Self.allowedTableNames.contains(table) else { return [] }
    return try connection.query("PRAGMA table_info(\(table))")
      .compactMap { $0["name"]?.string }
  }

  public func createInitialSetup(
    profile: BusinessProfile,
    fiscalYear: FiscalYear,
    at date: Date
  ) throws {
    let existing = try connection.scalarInt("SELECT COUNT(*) FROM business_profiles") ?? 0
    guard existing == 0 else { throw RepositoryError.duplicate("Initial setup") }
    try connection.transaction {
      try saveFiscalYear(fiscalYear)
      try saveProfile(profile)
      for account in StandardChartOfAccounts.accounts(createdAt: date) {
        try saveAccount(account)
      }
      try appendAudit(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
    }
  }

  public func saveFiscalYear(_ fiscalYear: FiscalYear) throws {
    try connection.execute(
      """
      INSERT INTO fiscal_years(
        id, calendar_year, status, tax_rule_set_id, form_rule_set_id,
        locked_at, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        calendar_year = excluded.calendar_year,
        status = excluded.status,
        tax_rule_set_id = excluded.tax_rule_set_id,
        form_rule_set_id = excluded.form_rule_set_id,
        locked_at = excluded.locked_at,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(fiscalYear.id.uuidString.lowercased()),
        .integer(Int64(fiscalYear.calendarYear)),
        .text(fiscalYear.status.rawValue),
        .text(fiscalYear.taxRuleSetID),
        .text(fiscalYear.formRuleSetID),
        fiscalYear.lockedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
        .real(fiscalYear.metadata.createdAt.timeIntervalSince1970),
        .real(fiscalYear.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func fiscalYears() throws -> [FiscalYear] {
    try connection.query(
      """
      SELECT id, calendar_year, status, tax_rule_set_id, form_rule_set_id,
             locked_at, created_at, updated_at
      FROM fiscal_years ORDER BY calendar_year
      """
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let year = row["calendar_year"]?.int64,
        let statusText = row["status"]?.string,
        let status = FiscalYearStatus(rawValue: statusText),
        let taxRuleSetID = row["tax_rule_set_id"]?.string,
        let createdAt = row["created_at"]?.double,
        let updatedAt = row["updated_at"]?.double
      else {
        throw V2DataError.invalidRow("fiscal_years")
      }
      return try FiscalYear(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: createdAt),
          updatedAt: Date(timeIntervalSince1970: updatedAt)
        ),
        calendarYear: Int(year),
        status: status,
        taxRuleSetID: taxRuleSetID,
        formRuleSetID: row["form_rule_set_id"]?.string
          ?? "form-\(year)-unavailable",
        lockedAt: row["locked_at"]?.double.map(Date.init(timeIntervalSince1970:))
      )
    }
  }

  public func saveProfile(_ profile: BusinessProfile) throws {
    try connection.execute(
      """
      INSERT INTO business_profiles(
        id, fiscal_year_id, owner_name, trade_name, postal_address,
        tax_address, tax_office, tax_office_code, e_tax_user_id, industry,
        opened_on, blue_return_approved, consumption_tax_status,
        invoice_registration_status, invoice_registration_number,
        invoice_registered_on, invoice_cancelled_on, bookkeeping_style,
        tax_accounting_method, rounding_rule, default_tax_rate,
        created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        fiscal_year_id = excluded.fiscal_year_id,
        owner_name = excluded.owner_name,
        trade_name = excluded.trade_name,
        postal_address = excluded.postal_address,
        tax_address = excluded.tax_address,
        tax_office = excluded.tax_office,
        tax_office_code = excluded.tax_office_code,
        e_tax_user_id = excluded.e_tax_user_id,
        industry = excluded.industry,
        opened_on = excluded.opened_on,
        blue_return_approved = excluded.blue_return_approved,
        consumption_tax_status = excluded.consumption_tax_status,
        invoice_registration_status = excluded.invoice_registration_status,
        invoice_registration_number = excluded.invoice_registration_number,
        invoice_registered_on = excluded.invoice_registered_on,
        invoice_cancelled_on = excluded.invoice_cancelled_on,
        bookkeeping_style = excluded.bookkeeping_style,
        tax_accounting_method = excluded.tax_accounting_method,
        rounding_rule = excluded.rounding_rule,
        default_tax_rate = excluded.default_tax_rate,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(profile.id.uuidString.lowercased()),
        .text(profile.fiscalYearID.uuidString.lowercased()),
        .text(profile.ownerName),
        .text(profile.tradeName),
        .text(profile.postalAddress),
        .text(profile.taxAddress),
        .text(profile.taxOffice),
        .text(profile.taxOfficeCode),
        .text(profile.eTaxUserID),
        .text(profile.industry),
        profile.openedOn.map { .real($0.timeIntervalSince1970) } ?? .null,
        .integer(profile.blueReturnApproved ? 1 : 0),
        .text(profile.consumptionTaxStatus.rawValue),
        .text(profile.invoiceRegistrationStatus.rawValue),
        profile.invoiceRegistrationNumber.map(SQLiteValue.text) ?? .null,
        profile.invoiceRegisteredOn.map { .real($0.timeIntervalSince1970) } ?? .null,
        profile.invoiceCancelledOn.map { .real($0.timeIntervalSince1970) } ?? .null,
        .text(profile.bookkeepingStyle.rawValue),
        .text(profile.taxAccountingMethod.rawValue),
        .text(profile.roundingRule.rawValue),
        .text(profile.defaultTaxRate.rawValue),
        .real(profile.metadata.createdAt.timeIntervalSince1970),
        .real(profile.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func updateProfile(_ profile: BusinessProfile, at date: Date) throws {
    try connection.transaction {
      try saveProfile(profile)
      try appendAudit(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
    }
  }

  public func profiles() throws -> [BusinessProfile] {
    try connection.query("SELECT * FROM business_profiles ORDER BY created_at").map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let fiscalYearID = row["fiscal_year_id"]?.string.flatMap(UUID.init(uuidString:)),
        let ownerName = row["owner_name"]?.string,
        let tradeName = row["trade_name"]?.string,
        let bookkeeping = row["bookkeeping_style"]?.string.flatMap(
          BookkeepingStyle.init(rawValue:)),
        let consumption = row["consumption_tax_status"]?.string.flatMap(
          ConsumptionTaxStatus.init(rawValue:)),
        let invoice = row["invoice_registration_status"]?.string.flatMap(
          InvoiceRegistrationStatus.init(rawValue:)),
        let accounting = row["tax_accounting_method"]?.string.flatMap(
          TaxAccountingMethod.init(rawValue:)),
        let rounding = row["rounding_rule"]?.string.flatMap(RoundingRule.init(rawValue:)),
        let defaultTax = row["default_tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
        let createdAt = row["created_at"]?.double,
        let updatedAt = row["updated_at"]?.double
      else {
        throw V2DataError.invalidRow("business_profiles")
      }
      return BusinessProfile(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: createdAt),
          updatedAt: Date(timeIntervalSince1970: updatedAt)
        ),
        fiscalYearID: fiscalYearID,
        ownerName: ownerName,
        tradeName: tradeName,
        postalAddress: row["postal_address"]?.string ?? "",
        taxAddress: row["tax_address"]?.string ?? "",
        taxOffice: row["tax_office"]?.string ?? "",
        taxOfficeCode: row["tax_office_code"]?.string ?? "",
        eTaxUserID: row["e_tax_user_id"]?.string ?? "",
        industry: row["industry"]?.string ?? "",
        openedOn: row["opened_on"]?.double.map(Date.init(timeIntervalSince1970:)),
        blueReturnApproved: row["blue_return_approved"]?.int64 == 1,
        bookkeepingStyle: bookkeeping,
        consumptionTaxStatus: consumption,
        invoiceRegistrationStatus: invoice,
        invoiceRegistrationNumber: row["invoice_registration_number"]?.string,
        invoiceRegisteredOn: row["invoice_registered_on"]?.double.map(
          Date.init(timeIntervalSince1970:)),
        invoiceCancelledOn: row["invoice_cancelled_on"]?.double.map(
          Date.init(timeIntervalSince1970:)),
        taxAccountingMethod: accounting,
        roundingRule: rounding,
        defaultTaxRate: defaultTax
      )
    }
  }

  public func saveAccount(_ account: Account) throws {
    try connection.execute(
      """
      INSERT INTO accounts(
        id, code, name, category, normal_balance, default_tax_rate,
        statement_section, display_order, is_active, is_system,
        created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        code = excluded.code,
        name = excluded.name,
        category = excluded.category,
        normal_balance = excluded.normal_balance,
        default_tax_rate = excluded.default_tax_rate,
        statement_section = excluded.statement_section,
        display_order = excluded.display_order,
        is_active = excluded.is_active,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(account.id.uuidString.lowercased()),
        .text(account.code),
        .text(account.name),
        .text(account.category.rawValue),
        .text(account.normalBalance.rawValue),
        .text(account.defaultTaxRate.rawValue),
        .text(account.statementSection.rawValue),
        .integer(Int64(account.displayOrder)),
        .integer(account.isActive ? 1 : 0),
        .integer(account.isSystem ? 1 : 0),
        .real(account.metadata.createdAt.timeIntervalSince1970),
        .real(account.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func accounts(includeInactive: Bool = false) throws -> [Account] {
    let whereClause = includeInactive ? "" : "WHERE is_active = 1"
    return try connection.query(
      "SELECT * FROM accounts \(whereClause) ORDER BY display_order, code"
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let code = row["code"]?.string,
        let name = row["name"]?.string,
        let category = row["category"]?.string.flatMap(AccountCategory.init(rawValue:)),
        let normal = row["normal_balance"]?.string.flatMap(BalanceDirection.init(rawValue:)),
        let taxRate = row["default_tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
        let section = row["statement_section"]?.string.flatMap(StatementSection.init(rawValue:)),
        let order = row["display_order"]?.int64,
        let createdAt = row["created_at"]?.double,
        let updatedAt = row["updated_at"]?.double
      else {
        throw V2DataError.invalidRow("accounts")
      }
      return Account(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: createdAt),
          updatedAt: Date(timeIntervalSince1970: updatedAt)
        ),
        code: code,
        name: name,
        category: category,
        normalBalance: normal,
        defaultTaxRate: taxRate,
        statementSection: section,
        displayOrder: Int(order),
        isActive: row["is_active"]?.int64 == 1,
        isSystem: row["is_system"]?.int64 == 1
      )
    }
  }

  public func saveJournalDraft(_ entry: JournalEntry) throws {
    try connection.transaction {
      try connection.execute(
        """
        INSERT INTO journal_entries(
          id, fiscal_year_id, transaction_date, description, kind, status,
          source_entry_id, reason, posted_at, created_at, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          transaction_date = excluded.transaction_date,
          description = excluded.description,
          kind = excluded.kind,
          status = excluded.status,
          source_entry_id = excluded.source_entry_id,
          reason = excluded.reason,
          posted_at = excluded.posted_at,
          updated_at = excluded.updated_at
        """,
        bindings: [
          .text(entry.id.uuidString.lowercased()),
          .text(entry.fiscalYearID.uuidString.lowercased()),
          .real(entry.transactionDate.timeIntervalSince1970),
          .text(entry.description),
          .text(entry.kind.rawValue),
          .text(entry.status.rawValue),
          entry.sourceEntryID.map { .text($0.uuidString.lowercased()) } ?? .null,
          entry.reason.map(SQLiteValue.text) ?? .null,
          entry.postedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
          .real(entry.metadata.createdAt.timeIntervalSince1970),
          .real(entry.metadata.updatedAt.timeIntervalSince1970),
        ]
      )
      try connection.execute(
        "DELETE FROM journal_lines WHERE journal_entry_id = ?",
        bindings: [.text(entry.id.uuidString.lowercased())]
      )
      for (sequence, line) in entry.lines.enumerated() {
        try connection.execute(
          """
          INSERT INTO journal_lines(
            id, journal_entry_id, sequence, account_id, sub_account_id,
            side, amount_yen, tax_rate, invoice_registration_status,
            deductible_basis_points, rounding_unit, counterparty, memo
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
          """,
          bindings: [
            .text(line.id.uuidString.lowercased()),
            .text(entry.id.uuidString.lowercased()),
            .integer(Int64(sequence)),
            .text(line.accountID.uuidString.lowercased()),
            line.subAccountID.map { .text($0.uuidString.lowercased()) } ?? .null,
            .text(line.side.rawValue),
            .integer(line.amount.yen),
            .text(line.taxRate.rawValue),
            .text(line.invoiceStatus.rawValue),
            .integer(Int64(line.deductibleBasisPoints)),
            .text(line.roundingUnit.rawValue),
            .text(line.counterparty),
            .text(line.memo),
          ]
        )
      }
    }
  }

  public func postJournal(
    id: UUID,
    fiscalYear: FiscalYear,
    at date: Date
  ) throws {
    guard var entry = try journalEntries().first(where: { $0.id == id }) else {
      throw RepositoryError.notFound
    }
    try entry.post(for: fiscalYear, at: date)
    try saveJournalDraft(entry)
    try appendAudit(
      AuditEvent(
        occurredAt: date,
        actorKind: .localUser,
        action: .created,
        targetType: "JournalEntry",
        targetID: id.uuidString.lowercased(),
        reason: "posted"
      )
    )
  }

  public func journalEntries(fiscalYearID: UUID? = nil) throws -> [JournalEntry] {
    let entries: [SQLiteRow]
    if let fiscalYearID {
      entries = try connection.query(
        "SELECT * FROM journal_entries WHERE fiscal_year_id = ? ORDER BY transaction_date, id",
        bindings: [.text(fiscalYearID.uuidString.lowercased())]
      )
    } else {
      entries = try connection.query(
        "SELECT * FROM journal_entries ORDER BY transaction_date, id"
      )
    }
    return try entries.map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let yearID = row["fiscal_year_id"]?.string.flatMap(UUID.init(uuidString:)),
        let transactionDate = row["transaction_date"]?.double,
        let description = row["description"]?.string,
        let kind = row["kind"]?.string.flatMap(JournalEntryKind.init(rawValue:)),
        let status = row["status"]?.string.flatMap(JournalEntryStatus.init(rawValue:)),
        let createdAt = row["created_at"]?.double,
        let updatedAt = row["updated_at"]?.double
      else {
        throw V2DataError.invalidRow("journal_entries")
      }
      let lineRows = try connection.query(
        "SELECT * FROM journal_lines WHERE journal_entry_id = ? ORDER BY sequence",
        bindings: [.text(id.uuidString.lowercased())]
      )
      let lines = try lineRows.map { line -> JournalLine in
        guard
          let lineID = line["id"]?.string.flatMap(UUID.init(uuidString:)),
          let accountID = line["account_id"]?.string.flatMap(UUID.init(uuidString:)),
          let side = line["side"]?.string.flatMap(PostingSide.init(rawValue:)),
          let amount = line["amount_yen"]?.int64,
          let taxRate = line["tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
          let invoice = line["invoice_registration_status"]?.string.flatMap(
            InvoiceRegistrationStatus.init(rawValue:)),
          let deductible = line["deductible_basis_points"]?.int64,
          let rounding = line["rounding_unit"]?.string.flatMap(RoundingUnit.init(rawValue:))
        else {
          throw V2DataError.invalidRow("journal_lines")
        }
        return try JournalLine(
          id: lineID,
          accountID: accountID,
          subAccountID: line["sub_account_id"]?.string.flatMap(UUID.init(uuidString:)),
          side: side,
          amount: Money(yen: amount),
          taxRate: taxRate,
          invoiceStatus: invoice,
          deductibleBasisPoints: Int(deductible),
          roundingUnit: rounding,
          counterparty: line["counterparty"]?.string ?? "",
          memo: line["memo"]?.string ?? ""
        )
      }
      return JournalEntry(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: createdAt),
          updatedAt: Date(timeIntervalSince1970: updatedAt)
        ),
        fiscalYearID: yearID,
        transactionDate: Date(timeIntervalSince1970: transactionDate),
        description: description,
        kind: kind,
        status: status,
        lines: lines,
        sourceEntryID: row["source_entry_id"]?.string.flatMap(UUID.init(uuidString:)),
        reason: row["reason"]?.string,
        postedAt: row["posted_at"]?.double.map(Date.init(timeIntervalSince1970:))
      )
    }
  }

  public func saveEvidence(
    _ document: EvidenceDocument,
    fiscalYearID: UUID?,
    ocrSnapshotJSON: String? = nil
  ) throws {
    try connection.execute(
      """
      INSERT INTO evidence_documents(
        id, fiscal_year_id, original_relative_path, original_filename,
        sha256, byte_count, mime_type, acquired_at, origin,
        transaction_date, amount_yen, counterparty_name, review_state,
        electronic_transaction, ocr_snapshot_json, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        fiscal_year_id = excluded.fiscal_year_id,
        transaction_date = excluded.transaction_date,
        amount_yen = excluded.amount_yen,
        counterparty_name = excluded.counterparty_name,
        review_state = excluded.review_state,
        ocr_snapshot_json = COALESCE(evidence_documents.ocr_snapshot_json, excluded.ocr_snapshot_json),
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(document.id.uuidString.lowercased()),
        fiscalYearID.map { .text($0.uuidString.lowercased()) } ?? .null,
        .text(document.originalRelativePath),
        .text(document.originalFilename),
        .text(document.originalSHA256),
        .integer(document.byteCount),
        .text(document.mimeType),
        .real(document.acquiredAt.timeIntervalSince1970),
        .text(document.origin.rawValue),
        document.transactionDate.map { .real($0.timeIntervalSince1970) } ?? .null,
        document.amount.map { .integer($0.yen) } ?? .null,
        document.counterparty.map(SQLiteValue.text) ?? .null,
        .text(document.state.rawValue),
        .integer(document.electronicTransaction ? 1 : 0),
        ocrSnapshotJSON.map(SQLiteValue.text) ?? .null,
        .real(document.metadata.createdAt.timeIntervalSince1970),
        .real(document.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
    try appendAudit(
      AuditEvent(
        occurredAt: document.metadata.updatedAt,
        actorKind: .localUser,
        action: .updated,
        targetType: "EvidenceDocument",
        targetID: document.id.uuidString.lowercased()
      )
    )
  }

  public func evidenceDocuments() throws -> [EvidenceDocument] {
    try connection.query(
      """
      SELECT * FROM evidence_documents
      ORDER BY acquired_at DESC, id
      """
    ).map(Self.decodeEvidence)
  }

  public func evidenceDocument(id: UUID) throws -> EvidenceDocument? {
    try connection.query(
      "SELECT * FROM evidence_documents WHERE id = ?",
      bindings: [.text(id.uuidString.lowercased())]
    ).first.map(Self.decodeEvidence)
  }

  public func saveOCRCandidates(_ candidates: [OCRCandidate]) throws {
    try connection.transaction {
      for candidate in candidates {
        try connection.execute(
          """
          INSERT INTO ocr_candidates(
            id, evidence_id, field, raw_value, confidence,
            corrected_value, corrected_at
          ) VALUES (?,?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET
            corrected_value = excluded.corrected_value,
            corrected_at = excluded.corrected_at
          """,
          bindings: [
            .text(candidate.id.uuidString.lowercased()),
            .text(candidate.evidenceID.uuidString.lowercased()),
            .text(candidate.field.rawValue),
            .text(candidate.rawValue),
            .real(candidate.confidence),
            candidate.correctedValue.map(SQLiteValue.text) ?? .null,
            candidate.correctedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
          ]
        )
      }
    }
  }

  public func ocrCandidates(evidenceID: UUID) throws -> [OCRCandidate] {
    try connection.query(
      """
      SELECT * FROM ocr_candidates
      WHERE evidence_id = ?
      ORDER BY field, confidence DESC
      """,
      bindings: [.text(evidenceID.uuidString.lowercased())]
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let evidenceID = row["evidence_id"]?.string.flatMap(UUID.init(uuidString:)),
        let field = row["field"]?.string.flatMap(OCRField.init(rawValue:)),
        let rawValue = row["raw_value"]?.string,
        let confidence = row["confidence"]?.double
      else { throw V2DataError.invalidRow("ocr_candidates") }
      return OCRCandidate(
        id: id,
        evidenceID: evidenceID,
        field: field,
        rawValue: rawValue,
        confidence: confidence,
        correctedValue: row["corrected_value"]?.string,
        correctedAt: row["corrected_at"]?.double.map(Date.init(timeIntervalSince1970:))
      )
    }
  }

  public func linkEvidence(
    evidenceID: UUID,
    journalEntryID: UUID,
    at date: Date
  ) throws {
    try connection.execute(
      """
      INSERT INTO evidence_links(id, evidence_id, journal_entry_id, linked_at)
      VALUES (?,?,?,?)
      ON CONFLICT(evidence_id, journal_entry_id) DO NOTHING
      """,
      bindings: [
        .text(UUID().uuidString.lowercased()),
        .text(evidenceID.uuidString.lowercased()),
        .text(journalEntryID.uuidString.lowercased()),
        .real(date.timeIntervalSince1970),
      ]
    )
  }

  public func saveImportCandidates(_ candidates: [StoredImportCandidateV2]) throws {
    try connection.transaction {
      for stored in candidates {
        let candidate = stored.candidate
        try connection.execute(
          """
          INSERT INTO import_candidates(
            id, source_kind, source_fingerprint, occurred_at, amount_yen,
            description, state, created_at, updated_at
          ) VALUES (?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_fingerprint) DO NOTHING
          """,
          bindings: [
            .text(candidate.id.uuidString.lowercased()),
            .text(candidate.sourceKind),
            .text(candidate.sourceFingerprint),
            candidate.occurredAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            candidate.amountYen.map(SQLiteValue.integer) ?? .null,
            .text(candidate.description),
            .text(stored.state.rawValue),
            .real(stored.createdAt.timeIntervalSince1970),
            .real(stored.updatedAt.timeIntervalSince1970),
          ]
        )
        guard
          let storedID = try connection.query(
            "SELECT id FROM import_candidates WHERE source_fingerprint = ?",
            bindings: [.text(candidate.sourceFingerprint)]
          ).first?["id"]?.string
        else { throw V2DataError.invalidRow("import_candidates") }
        try connection.execute(
          "DELETE FROM import_candidate_warnings WHERE import_candidate_id = ?",
          bindings: [.text(storedID)]
        )
        for (sequence, warning) in candidate.warnings.enumerated() {
          try connection.execute(
            """
            INSERT INTO import_candidate_warnings(
              import_candidate_id, sequence, warning
            ) VALUES (?,?,?)
            """,
            bindings: [
              .text(storedID),
              .integer(Int64(sequence)),
              .text(warning),
            ]
          )
        }
      }
    }
  }

  public func importCandidates(
    state: ImportCandidateStateV2? = nil
  ) throws -> [StoredImportCandidateV2] {
    let rows =
      try state.map {
        try connection.query(
          "SELECT * FROM import_candidates WHERE state = ? ORDER BY occurred_at, created_at",
          bindings: [.text($0.rawValue)]
        )
      }
      ?? connection.query("SELECT * FROM import_candidates ORDER BY occurred_at, created_at")
    return try rows.map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let sourceKind = row["source_kind"]?.string,
        let fingerprint = row["source_fingerprint"]?.string,
        let description = row["description"]?.string,
        let state = row["state"]?.string.flatMap(ImportCandidateStateV2.init(rawValue:)),
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("import_candidates") }
      let warnings = try connection.query(
        """
        SELECT warning FROM import_candidate_warnings
        WHERE import_candidate_id = ? ORDER BY sequence
        """,
        bindings: [.text(id.uuidString.lowercased())]
      ).compactMap { $0["warning"]?.string }
      return StoredImportCandidateV2(
        candidate: ImportCandidateV1(
          id: id,
          sourceKind: sourceKind,
          sourceFingerprint: fingerprint,
          occurredAt: row["occurred_at"]?.double.map(Date.init(timeIntervalSince1970:)),
          amountYen: row["amount_yen"]?.int64,
          description: description,
          warnings: warnings
        ),
        state: state,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func markImportCandidate(
    id: UUID,
    state: ImportCandidateStateV2,
    at date: Date
  ) throws {
    try connection.execute(
      "UPDATE import_candidates SET state = ?, updated_at = ? WHERE id = ?",
      bindings: [
        .text(state.rawValue),
        .real(date.timeIntervalSince1970),
        .text(id.uuidString.lowercased()),
      ]
    )
  }

  public func saveJournalTemplate(_ template: JournalTemplateV2) throws {
    try connection.execute(
      """
      INSERT INTO journal_templates(
        id, name, default_description, debit_account_id, credit_account_id,
        tax_rate, invoice_registration_status, is_active, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        default_description = excluded.default_description,
        debit_account_id = excluded.debit_account_id,
        credit_account_id = excluded.credit_account_id,
        tax_rate = excluded.tax_rate,
        invoice_registration_status = excluded.invoice_registration_status,
        is_active = excluded.is_active,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(template.id.uuidString.lowercased()),
        .text(template.name),
        .text(template.defaultDescription),
        .text(template.debitAccountID.uuidString.lowercased()),
        .text(template.creditAccountID.uuidString.lowercased()),
        .text(template.taxRate.rawValue),
        .text(template.invoiceStatus.rawValue),
        .integer(template.isActive ? 1 : 0),
        .real(template.createdAt.timeIntervalSince1970),
        .real(template.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func journalTemplates() throws -> [JournalTemplateV2] {
    try connection.query(
      "SELECT * FROM journal_templates ORDER BY name, id"
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let name = row["name"]?.string,
        let description = row["default_description"]?.string,
        let debit = row["debit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
        let credit = row["credit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
        let tax = row["tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
        let invoice = row["invoice_registration_status"]?.string.flatMap(
          InvoiceRegistrationStatus.init(rawValue:)),
        let active = row["is_active"]?.int64,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("journal_templates") }
      return JournalTemplateV2(
        id: id,
        name: name,
        defaultDescription: description,
        debitAccountID: debit,
        creditAccountID: credit,
        taxRate: tax,
        invoiceStatus: invoice,
        isActive: active != 0,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func saveJournalRule(_ rule: JournalRuleV2) throws {
    try connection.execute(
      """
      INSERT INTO journal_rules(
        id, name, description_contains, debit_account_id, credit_account_id,
        tax_rate, priority, is_active, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        description_contains = excluded.description_contains,
        debit_account_id = excluded.debit_account_id,
        credit_account_id = excluded.credit_account_id,
        tax_rate = excluded.tax_rate,
        priority = excluded.priority,
        is_active = excluded.is_active,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(rule.id.uuidString.lowercased()),
        .text(rule.name),
        .text(rule.descriptionContains),
        .text(rule.debitAccountID.uuidString.lowercased()),
        .text(rule.creditAccountID.uuidString.lowercased()),
        .text(rule.taxRate.rawValue),
        .integer(Int64(rule.priority)),
        .integer(rule.isActive ? 1 : 0),
        .real(rule.createdAt.timeIntervalSince1970),
        .real(rule.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func journalRules() throws -> [JournalRuleV2] {
    try connection.query(
      "SELECT * FROM journal_rules ORDER BY priority, name, id"
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let name = row["name"]?.string,
        let contains = row["description_contains"]?.string,
        let debit = row["debit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
        let credit = row["credit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
        let tax = row["tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
        let priority = row["priority"]?.int64,
        let active = row["is_active"]?.int64,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("journal_rules") }
      return JournalRuleV2(
        id: id,
        name: name,
        descriptionContains: contains,
        debitAccountID: debit,
        creditAccountID: credit,
        taxRate: tax,
        priority: Int(priority),
        isActive: active != 0,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func saveRecurringJournal(_ recurring: RecurringJournalV2) throws {
    try connection.execute(
      """
      INSERT INTO recurring_journals(
        id, template_id, frequency, day_of_month, amount_yen,
        next_run_at, is_active, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        template_id = excluded.template_id,
        frequency = excluded.frequency,
        day_of_month = excluded.day_of_month,
        amount_yen = excluded.amount_yen,
        next_run_at = excluded.next_run_at,
        is_active = excluded.is_active,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(recurring.id.uuidString.lowercased()),
        .text(recurring.templateID.uuidString.lowercased()),
        .text(recurring.frequency.rawValue),
        .integer(Int64(recurring.dayOfMonth)),
        .integer(recurring.amountYen),
        .real(recurring.nextRunAt.timeIntervalSince1970),
        .integer(recurring.isActive ? 1 : 0),
        .real(recurring.createdAt.timeIntervalSince1970),
        .real(recurring.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func recurringJournals(dueAt date: Date? = nil) throws -> [RecurringJournalV2] {
    let rows: [SQLiteRow]
    if let date {
      rows = try connection.query(
        "SELECT * FROM recurring_journals WHERE is_active = 1 AND next_run_at <= ? ORDER BY next_run_at",
        bindings: [.real(date.timeIntervalSince1970)]
      )
    } else {
      rows = try connection.query("SELECT * FROM recurring_journals ORDER BY next_run_at")
    }
    return try rows.map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let templateID = row["template_id"]?.string.flatMap(UUID.init(uuidString:)),
        let frequency = row["frequency"]?.string.flatMap(RecurrenceFrequencyV2.init(rawValue:)),
        let day = row["day_of_month"]?.int64,
        let amount = row["amount_yen"]?.int64,
        let nextRun = row["next_run_at"]?.double,
        let active = row["is_active"]?.int64,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("recurring_journals") }
      return RecurringJournalV2(
        id: id,
        templateID: templateID,
        frequency: frequency,
        dayOfMonth: Int(day),
        amountYen: amount,
        nextRunAt: Date(timeIntervalSince1970: nextRun),
        isActive: active != 0,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func advanceRecurringJournal(id: UUID, nextRunAt: Date, at date: Date) throws {
    try connection.execute(
      """
      UPDATE recurring_journals
      SET next_run_at = ?, updated_at = ?
      WHERE id = ? AND is_active = 1
      """,
      bindings: [
        .real(nextRunAt.timeIntervalSince1970),
        .real(date.timeIntervalSince1970),
        .text(id.uuidString.lowercased()),
      ]
    )
  }

  public func saveJournalCandidate(_ candidate: JournalCandidateV2) throws {
    try connection.execute(
      """
      INSERT INTO journal_candidates(
        id, idempotency_key, source_kind, source_id, transaction_date,
        description, amount_yen, debit_account_id, credit_account_id,
        tax_rate, invoice_registration_status, confidence_basis_points,
        explanation, state, journal_entry_id, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(idempotency_key) DO NOTHING
      """,
      bindings: [
        .text(candidate.id.uuidString.lowercased()),
        .text(candidate.idempotencyKey),
        .text(candidate.sourceKind),
        candidate.sourceID.map { .text($0.uuidString.lowercased()) } ?? .null,
        .real(candidate.transactionDate.timeIntervalSince1970),
        .text(candidate.description),
        .integer(candidate.amountYen),
        .text(candidate.debitAccountID.uuidString.lowercased()),
        .text(candidate.creditAccountID.uuidString.lowercased()),
        .text(candidate.taxRate.rawValue),
        .text(candidate.invoiceStatus.rawValue),
        .integer(Int64(candidate.confidenceBasisPoints)),
        .text(candidate.explanation),
        .text(candidate.state.rawValue),
        candidate.journalEntryID.map { .text($0.uuidString.lowercased()) } ?? .null,
        .real(candidate.createdAt.timeIntervalSince1970),
        .real(candidate.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func journalCandidates(
    state: JournalCandidateStateV2? = nil
  ) throws -> [JournalCandidateV2] {
    let rows =
      try state.map {
        try connection.query(
          "SELECT * FROM journal_candidates WHERE state = ? ORDER BY transaction_date, created_at",
          bindings: [.text($0.rawValue)]
        )
      }
      ?? connection.query("SELECT * FROM journal_candidates ORDER BY transaction_date, created_at")
    return try rows.map(Self.decodeJournalCandidate)
  }

  public func markJournalCandidate(
    id: UUID,
    state: JournalCandidateStateV2,
    journalEntryID: UUID?,
    at date: Date
  ) throws {
    try connection.execute(
      """
      UPDATE journal_candidates
      SET state = ?, journal_entry_id = ?, updated_at = ?
      WHERE id = ? AND state = 'pending'
      """,
      bindings: [
        .text(state.rawValue),
        journalEntryID.map { .text($0.uuidString.lowercased()) } ?? .null,
        .real(date.timeIntervalSince1970),
        .text(id.uuidString.lowercased()),
      ]
    )
  }

  public func saveMatchCandidate(_ candidate: MatchCandidateV2) throws {
    try connection.execute(
      """
      INSERT INTO match_candidates(
        id, idempotency_key, import_candidate_id, evidence_id,
        journal_candidate_id, confidence_basis_points, explanation,
        state, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(idempotency_key) DO NOTHING
      """,
      bindings: [
        .text(candidate.id.uuidString.lowercased()),
        .text(candidate.idempotencyKey),
        .text(candidate.importCandidateID.uuidString.lowercased()),
        .text(candidate.evidenceID.uuidString.lowercased()),
        candidate.journalCandidateID.map { .text($0.uuidString.lowercased()) } ?? .null,
        .integer(Int64(candidate.confidenceBasisPoints)),
        .text(candidate.explanation),
        .text(candidate.state.rawValue),
        .real(candidate.createdAt.timeIntervalSince1970),
        .real(candidate.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func matchCandidates(
    state: MatchCandidateStateV2? = nil
  ) throws -> [MatchCandidateV2] {
    let rows =
      try state.map {
        try connection.query(
          "SELECT * FROM match_candidates WHERE state = ? ORDER BY confidence_basis_points DESC",
          bindings: [.text($0.rawValue)]
        )
      }
      ?? connection.query(
        "SELECT * FROM match_candidates ORDER BY confidence_basis_points DESC, created_at"
      )
    return try rows.map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let key = row["idempotency_key"]?.string,
        let imported = row["import_candidate_id"]?.string.flatMap(UUID.init(uuidString:)),
        let evidence = row["evidence_id"]?.string.flatMap(UUID.init(uuidString:)),
        let confidence = row["confidence_basis_points"]?.int64,
        let explanation = row["explanation"]?.string,
        let state = row["state"]?.string.flatMap(MatchCandidateStateV2.init(rawValue:)),
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("match_candidates") }
      return MatchCandidateV2(
        id: id,
        idempotencyKey: key,
        importCandidateID: imported,
        evidenceID: evidence,
        journalCandidateID: row["journal_candidate_id"]?.string.flatMap(UUID.init(uuidString:)),
        confidenceBasisPoints: Int(confidence),
        explanation: explanation,
        state: state,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func markMatchCandidate(
    id: UUID,
    state: MatchCandidateStateV2,
    at date: Date
  ) throws {
    try connection.transaction {
      guard
        let importID = try connection.query(
          "SELECT import_candidate_id FROM match_candidates WHERE id = ?",
          bindings: [.text(id.uuidString.lowercased())]
        ).first?["import_candidate_id"]?.string
      else { throw RepositoryError.notFound }
      try connection.execute(
        """
        UPDATE match_candidates
        SET state = ?, updated_at = ?
        WHERE id = ? AND state = 'pending'
        """,
        bindings: [
          .text(state.rawValue),
          .real(date.timeIntervalSince1970),
          .text(id.uuidString.lowercased()),
        ]
      )
      if state == .accepted {
        try connection.execute(
          """
          UPDATE import_candidates SET state = 'matched', updated_at = ?
          WHERE id = ?
          """,
          bindings: [.real(date.timeIntervalSince1970), .text(importID)]
        )
      }
    }
  }

  public func acceptedMatch(journalCandidateID: UUID) throws -> MatchCandidateV2? {
    try matchCandidates(state: .accepted).first {
      $0.journalCandidateID == journalCandidateID
    }
  }

  public func saveCounterparty(_ counterparty: Counterparty) throws {
    try connection.transaction {
      try connection.execute(
        """
        INSERT INTO counterparties(
          id, code, display_name, postal_code, address, contact_name, email,
          invoice_registration_status, invoice_registration_number,
          payment_terms_days, withholding_default_enabled, is_active,
          created_at, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          code = excluded.code,
          display_name = excluded.display_name,
          postal_code = excluded.postal_code,
          address = excluded.address,
          contact_name = excluded.contact_name,
          email = excluded.email,
          invoice_registration_status = excluded.invoice_registration_status,
          invoice_registration_number = excluded.invoice_registration_number,
          payment_terms_days = excluded.payment_terms_days,
          withholding_default_enabled = excluded.withholding_default_enabled,
          is_active = excluded.is_active,
          updated_at = excluded.updated_at
        """,
        bindings: [
          .text(counterparty.id.uuidString.lowercased()),
          .text(counterparty.code),
          .text(counterparty.displayName),
          .text(counterparty.postalCode),
          .text(counterparty.address),
          .text(counterparty.contactName),
          .text(counterparty.email),
          .text(counterparty.invoiceRegistrationStatus.rawValue),
          counterparty.invoiceRegistrationNumber.map(SQLiteValue.text) ?? .null,
          .integer(Int64(counterparty.paymentTermsDays)),
          .integer(counterparty.withholdingDefaultEnabled ? 1 : 0),
          .integer(counterparty.isActive ? 1 : 0),
          .real(counterparty.metadata.createdAt.timeIntervalSince1970),
          .real(counterparty.metadata.updatedAt.timeIntervalSince1970),
        ]
      )
      try connection.execute(
        "DELETE FROM counterparty_roles WHERE counterparty_id = ?",
        bindings: [.text(counterparty.id.uuidString.lowercased())]
      )
      for role in counterparty.roles {
        try connection.execute(
          "INSERT INTO counterparty_roles(counterparty_id, role) VALUES (?,?)",
          bindings: [
            .text(counterparty.id.uuidString.lowercased()),
            .text(role.rawValue),
          ]
        )
      }
      try appendAudit(
        AuditEvent(
          occurredAt: counterparty.metadata.updatedAt,
          actorKind: .localUser,
          action: .updated,
          targetType: "Counterparty",
          targetID: counterparty.id.uuidString.lowercased()
        )
      )
    }
  }

  public func counterparties(includeInactive: Bool = false) throws -> [Counterparty] {
    let whereClause = includeInactive ? "" : "WHERE is_active = 1"
    return try connection.query(
      "SELECT * FROM counterparties \(whereClause) ORDER BY code, display_name"
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let code = row["code"]?.string,
        let displayName = row["display_name"]?.string,
        let invoice = row["invoice_registration_status"]?.string.flatMap(
          InvoiceRegistrationStatus.init(rawValue:)),
        let terms = row["payment_terms_days"]?.int64,
        let withholding = row["withholding_default_enabled"]?.int64,
        let active = row["is_active"]?.int64,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("counterparties") }
      let roles = try connection.query(
        "SELECT role FROM counterparty_roles WHERE counterparty_id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).compactMap { $0["role"]?.string.flatMap(CounterpartyRole.init(rawValue:)) }
      return Counterparty(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: created),
          updatedAt: Date(timeIntervalSince1970: updated)
        ),
        code: code,
        displayName: displayName,
        roles: Set(roles),
        postalCode: row["postal_code"]?.string ?? "",
        address: row["address"]?.string ?? "",
        contactName: row["contact_name"]?.string ?? "",
        email: row["email"]?.string ?? "",
        invoiceRegistrationStatus: invoice,
        invoiceRegistrationNumber: row["invoice_registration_number"]?.string,
        paymentTermsDays: Int(terms),
        withholdingDefaultEnabled: withholding != 0,
        isActive: active != 0
      )
    }
  }

  public func saveInvoice(_ invoice: Invoice) throws {
    let summaries = try invoice.taxSummaries()
    let subtotal = summaries.reduce(Int64(0)) { $0 + $1.netAmount.yen }
    let tax = summaries.reduce(Int64(0)) { $0 + $1.taxAmount.yen }
    let total = try invoice.total().yen
    let outstanding = try invoice.outstandingAmount().yen
    try connection.transaction {
      try connection.execute(
        """
        INSERT INTO invoices(
          id, fiscal_year_id, counterparty_id, number, kind, issue_date,
          due_date, subject, status, rounding_rule, issuer_name, issuer_address,
          issuer_registration_status, issuer_registration_number,
          source_invoice_id, reason, journal_entry_id, evidence_id,
          subtotal_yen, tax_yen, total_yen, outstanding_yen, created_at, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          counterparty_id = excluded.counterparty_id,
          number = excluded.number,
          kind = excluded.kind,
          issue_date = excluded.issue_date,
          due_date = excluded.due_date,
          subject = excluded.subject,
          status = excluded.status,
          rounding_rule = excluded.rounding_rule,
          issuer_name = excluded.issuer_name,
          issuer_address = excluded.issuer_address,
          issuer_registration_status = excluded.issuer_registration_status,
          issuer_registration_number = excluded.issuer_registration_number,
          source_invoice_id = excluded.source_invoice_id,
          reason = excluded.reason,
          journal_entry_id = excluded.journal_entry_id,
          evidence_id = excluded.evidence_id,
          subtotal_yen = excluded.subtotal_yen,
          tax_yen = excluded.tax_yen,
          total_yen = excluded.total_yen,
          outstanding_yen = excluded.outstanding_yen,
          updated_at = excluded.updated_at
        """,
        bindings: [
          .text(invoice.id.uuidString.lowercased()),
          .text(invoice.fiscalYearID.uuidString.lowercased()),
          .text(invoice.counterpartyID.uuidString.lowercased()),
          .text(invoice.number),
          .text(invoice.kind.rawValue),
          .real(invoice.issueDate.timeIntervalSince1970),
          .real(invoice.dueDate.timeIntervalSince1970),
          .text(invoice.subject),
          .text(invoice.status.rawValue),
          .text(invoice.roundingRule.rawValue),
          .text(invoice.issuerName),
          .text(invoice.issuerAddress),
          .text(invoice.issuerRegistrationStatus.rawValue),
          invoice.issuerRegistrationNumber.map(SQLiteValue.text) ?? .null,
          invoice.sourceInvoiceID.map { .text($0.uuidString.lowercased()) } ?? .null,
          invoice.reason.map(SQLiteValue.text) ?? .null,
          invoice.journalEntryID.map { .text($0.uuidString.lowercased()) } ?? .null,
          invoice.evidenceID.map { .text($0.uuidString.lowercased()) } ?? .null,
          .integer(subtotal),
          .integer(tax),
          .integer(total),
          .integer(outstanding),
          .real(invoice.metadata.createdAt.timeIntervalSince1970),
          .real(invoice.metadata.updatedAt.timeIntervalSince1970),
        ]
      )
      try connection.execute(
        "DELETE FROM invoice_items WHERE invoice_id = ?",
        bindings: [.text(invoice.id.uuidString.lowercased())]
      )
      for (sequence, line) in invoice.lines.enumerated() {
        try connection.execute(
          """
          INSERT INTO invoice_items(
            id, invoice_id, sequence, description, quantity,
            unit_price_yen, tax_rate, amount_yen
          ) VALUES (?,?,?,?,?,?,?,?)
          """,
          bindings: [
            .text(line.id.uuidString.lowercased()),
            .text(invoice.id.uuidString.lowercased()),
            .integer(Int64(sequence)),
            .text(line.description),
            .integer(line.quantity),
            .integer(line.unitPrice.yen),
            .text(line.taxRate.rawValue),
            .integer(try line.netAmount().yen),
          ]
        )
      }
      try connection.execute(
        "DELETE FROM settlements WHERE invoice_id = ?",
        bindings: [.text(invoice.id.uuidString.lowercased())]
      )
      for settlement in invoice.settlements {
        try connection.execute(
          """
          INSERT INTO settlements(
            id, invoice_id, settled_at, applied_amount_yen, cash_received_yen,
            fee_yen, withholding_yen, discount_yen, overpayment_yen,
            source_transaction_id, journal_entry_id, created_at
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          """,
          bindings: [
            .text(settlement.id.uuidString.lowercased()),
            .text(invoice.id.uuidString.lowercased()),
            .real(settlement.receivedAt.timeIntervalSince1970),
            .integer(settlement.appliedAmount.yen),
            .integer(settlement.cashReceived.yen),
            .integer(settlement.bankFee.yen),
            .integer(settlement.withholdingTax.yen),
            .integer(settlement.discount.yen),
            .integer(settlement.overpayment.yen),
            settlement.sourceTransactionID.map { .text($0.uuidString.lowercased()) } ?? .null,
            settlement.journalEntryID.map { .text($0.uuidString.lowercased()) } ?? .null,
            .real(invoice.metadata.updatedAt.timeIntervalSince1970),
          ]
        )
      }
      try appendAudit(
        AuditEvent(
          occurredAt: invoice.metadata.updatedAt,
          actorKind: .localUser,
          action: .updated,
          targetType: "Invoice",
          targetID: invoice.id.uuidString.lowercased()
        )
      )
    }
  }

  public func invoices(fiscalYearID: UUID? = nil) throws -> [Invoice] {
    let rows =
      try fiscalYearID.map {
        try connection.query(
          "SELECT * FROM invoices WHERE fiscal_year_id = ? ORDER BY issue_date DESC, number",
          bindings: [.text($0.uuidString.lowercased())]
        )
      } ?? connection.query("SELECT * FROM invoices ORDER BY issue_date DESC, number")
    return try rows.map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let yearID = row["fiscal_year_id"]?.string.flatMap(UUID.init(uuidString:)),
        let counterpartyID = row["counterparty_id"]?.string.flatMap(UUID.init(uuidString:)),
        let number = row["number"]?.string,
        let issueDate = row["issue_date"]?.double,
        let dueDate = row["due_date"]?.double,
        let subject = row["subject"]?.string,
        let kind = row["kind"]?.string.flatMap(InvoiceKind.init(rawValue:)),
        let status = row["status"]?.string.flatMap(InvoiceStatus.init(rawValue:)),
        let rounding = row["rounding_rule"]?.string.flatMap(RoundingRule.init(rawValue:)),
        let issuerName = row["issuer_name"]?.string,
        let issuerAddress = row["issuer_address"]?.string,
        let issuerStatus = row["issuer_registration_status"]?.string.flatMap(
          InvoiceRegistrationStatus.init(rawValue:)),
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("invoices") }
      let lineRows = try connection.query(
        "SELECT * FROM invoice_items WHERE invoice_id = ? ORDER BY sequence",
        bindings: [.text(id.uuidString.lowercased())]
      )
      let lines = try lineRows.map { line -> InvoiceLine in
        guard
          let lineID = line["id"]?.string.flatMap(UUID.init(uuidString:)),
          let description = line["description"]?.string,
          let quantity = line["quantity"]?.int64,
          let unitPrice = line["unit_price_yen"]?.int64,
          let taxRate = line["tax_rate"]?.string.flatMap(TaxRate.init(rawValue:))
        else { throw V2DataError.invalidRow("invoice_items") }
        return try InvoiceLine(
          id: lineID,
          description: description,
          quantity: quantity,
          unitPrice: Money(yen: unitPrice),
          taxRate: taxRate
        )
      }
      let settlementRows = try connection.query(
        "SELECT * FROM settlements WHERE invoice_id = ? ORDER BY settled_at",
        bindings: [.text(id.uuidString.lowercased())]
      )
      let settlements = try settlementRows.map { settlement -> InvoiceSettlement in
        guard
          let settlementID = settlement["id"]?.string.flatMap(UUID.init(uuidString:)),
          let received = settlement["settled_at"]?.double,
          let applied = settlement["applied_amount_yen"]?.int64,
          let cash = settlement["cash_received_yen"]?.int64,
          let fee = settlement["fee_yen"]?.int64,
          let withholding = settlement["withholding_yen"]?.int64,
          let discount = settlement["discount_yen"]?.int64,
          let overpayment = settlement["overpayment_yen"]?.int64
        else { throw V2DataError.invalidRow("settlements") }
        return try InvoiceSettlement(
          id: settlementID,
          receivedAt: Date(timeIntervalSince1970: received),
          appliedAmount: Money(yen: applied),
          cashReceived: Money(yen: cash),
          bankFee: Money(yen: fee),
          withholdingTax: Money(yen: withholding),
          discount: Money(yen: discount),
          overpayment: Money(yen: overpayment),
          sourceTransactionID: settlement["source_transaction_id"]?.string.flatMap(
            UUID.init(uuidString:)),
          journalEntryID: settlement["journal_entry_id"]?.string.flatMap(UUID.init(uuidString:))
        )
      }
      return try Invoice(
        metadata: EntityMetadata(
          id: id,
          createdAt: Date(timeIntervalSince1970: created),
          updatedAt: Date(timeIntervalSince1970: updated)
        ),
        fiscalYearID: yearID,
        counterpartyID: counterpartyID,
        number: number,
        issueDate: Date(timeIntervalSince1970: issueDate),
        dueDate: Date(timeIntervalSince1970: dueDate),
        subject: subject,
        kind: kind,
        status: status,
        lines: lines,
        roundingRule: rounding,
        issuerName: issuerName,
        issuerAddress: issuerAddress,
        issuerRegistrationStatus: issuerStatus,
        issuerRegistrationNumber: row["issuer_registration_number"]?.string,
        sourceInvoiceID: row["source_invoice_id"]?.string.flatMap(UUID.init(uuidString:)),
        reason: row["reason"]?.string,
        journalEntryID: row["journal_entry_id"]?.string.flatMap(UUID.init(uuidString:)),
        evidenceID: row["evidence_id"]?.string.flatMap(UUID.init(uuidString:)),
        settlements: settlements
      )
    }
  }

  @discardableResult
  public func issueInvoice(
    _ proposedInvoice: Invoice,
    accounts: InvoiceIssueAccounts,
    at date: Date,
    fileManager: FileManager = .default
  ) throws -> Invoice {
    if let existing = try invoices().first(where: { $0.id == proposedInvoice.id }),
      existing.journalEntryID != nil
    {
      return existing
    }
    guard
      let fiscalYear = try fiscalYears().first(where: {
        $0.id == proposedInvoice.fiscalYearID
      }),
      let counterparty = try counterparties(includeInactive: true).first(where: {
        $0.id == proposedInvoice.counterpartyID
      })
    else {
      throw RepositoryError.notFound
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    if let duplicate = try invoices().first(where: { $0.number == proposedInvoice.number }),
      duplicate.id != proposedInvoice.id
    {
      throw BillingError.duplicateNumber
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
    let evidenceID = UUID()
    let storedFilename = "\(evidenceID.uuidString.lowercased()).pdf"
    let storedURL = layout.evidenceOriginalsDirectory.appendingPathComponent(storedFilename)
    try pdf.write(to: storedURL, options: .atomic)
    let hash = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
    let document = EvidenceDocument(
      metadata: EntityMetadata(id: evidenceID, createdAt: date),
      originalSHA256: hash,
      originalRelativePath: "Evidence/Originals/\(storedFilename)",
      originalFilename: "\(proposedInvoice.number).pdf",
      mimeType: "application/pdf",
      byteCount: Int64(pdf.count),
      acquiredAt: date,
      origin: .electronicTransaction,
      state: .posted,
      transactionDate: proposedInvoice.issueDate,
      amount: try proposedInvoice.total(),
      counterparty: counterparty.displayName,
      electronicTransaction: false
    )
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: proposedInvoice.fiscalYearID,
      transactionDate: proposedInvoice.issueDate,
      description: "請求 \(proposedInvoice.number) \(proposedInvoice.subject)",
      lines: try Self.invoiceIssueLines(
        invoice: proposedInvoice,
        accounts: accounts,
        counterparty: counterparty.displayName
      )
    )
    try entry.post(for: fiscalYear, at: date)
    var invoice = proposedInvoice
    try invoice.markIssued(journalEntryID: entry.id, evidenceID: document.id, at: date)

    do {
      try connection.transaction {
        try saveJournalDraft(entry)
        try saveEvidence(document, fiscalYearID: fiscalYear.id)
        try linkEvidence(evidenceID: document.id, journalEntryID: entry.id, at: date)
        try saveInvoice(invoice)
        try appendAudit(
          AuditEvent(
            occurredAt: date,
            actorKind: .localUser,
            action: .created,
            targetType: "Invoice",
            targetID: invoice.id.uuidString.lowercased(),
            reason: "issued:\(invoice.number)"
          )
        )
      }
      return invoice
    } catch {
      try? fileManager.removeItem(at: storedURL)
      throw error
    }
  }

  @discardableResult
  public func settleInvoice(
    invoiceID: UUID,
    settlement: InvoiceSettlement,
    accounts: ReceivableSettlementAccounts,
    at date: Date
  ) throws -> Invoice {
    guard var invoice = try invoices().first(where: { $0.id == invoiceID }),
      let fiscalYear = try fiscalYears().first(where: { $0.id == invoice.fiscalYearID })
    else {
      throw RepositoryError.notFound
    }
    if invoice.settlements.contains(where: { $0.id == settlement.id }) {
      return invoice
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    var lines: [JournalLine] = []
    try Self.appendJournalLine(
      to: &lines,
      accountID: accounts.bankAccountID,
      side: .debit,
      amount: settlement.cashReceived
    )
    try Self.appendJournalLine(
      to: &lines,
      accountID: accounts.bankFeeAccountID,
      side: .debit,
      amount: settlement.bankFee
    )
    try Self.appendJournalLine(
      to: &lines,
      accountID: accounts.withholdingAccountID,
      side: .debit,
      amount: settlement.withholdingTax
    )
    try Self.appendJournalLine(
      to: &lines,
      accountID: accounts.discountAccountID,
      side: .debit,
      amount: settlement.discount
    )
    try Self.appendJournalLine(
      to: &lines,
      accountID: accounts.receivableAccountID,
      side: .credit,
      amount: settlement.appliedAmount
    )
    try Self.appendJournalLine(
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
      try saveJournalDraft(entry)
      try saveInvoice(invoice)
      try appendAudit(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "Invoice",
          targetID: invoice.id.uuidString.lowercased(),
          reason: "settlement:\(recorded.appliedAmount.yen)"
        )
      )
    }
    return invoice
  }

  public func saveClosingDecision(_ decision: ClosingDecisionV2) throws {
    try connection.execute(
      """
      INSERT INTO closing_decisions(
        id, fiscal_year_id, decision_type, status, amount_yen,
        rationale, source_snapshot_json, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        decision_type = excluded.decision_type,
        status = excluded.status,
        amount_yen = excluded.amount_yen,
        rationale = excluded.rationale,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(decision.id.uuidString.lowercased()),
        .text(decision.fiscalYearID.uuidString.lowercased()),
        .text(decision.decisionType),
        .text(decision.state.rawValue),
        decision.amountYen.map(SQLiteValue.integer) ?? .null,
        .text(decision.rationale),
        .null,
        .real(decision.createdAt.timeIntervalSince1970),
        .real(decision.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func closingDecisions(fiscalYearID: UUID) throws -> [ClosingDecisionV2] {
    try connection.query(
      """
      SELECT * FROM closing_decisions
      WHERE fiscal_year_id = ?
      ORDER BY decision_type, created_at
      """,
      bindings: [.text(fiscalYearID.uuidString.lowercased())]
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let yearID = row["fiscal_year_id"]?.string.flatMap(UUID.init(uuidString:)),
        let type = row["decision_type"]?.string,
        let state = row["status"]?.string.flatMap(ClosingDecisionStateV2.init(rawValue:)),
        let rationale = row["rationale"]?.string,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else { throw V2DataError.invalidRow("closing_decisions") }
      return ClosingDecisionV2(
        id: id,
        fiscalYearID: yearID,
        decisionType: type,
        state: state,
        amountYen: row["amount_yen"]?.int64,
        rationale: rationale,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func auditEvents() throws -> [AuditEvent] {
    try connection.query(
      "SELECT * FROM audit_events ORDER BY occurred_at DESC, id DESC"
    ).map { row in
      guard
        let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
        let occurred = row["occurred_at"]?.double,
        let actor = row["actor_kind"]?.string.flatMap(AuditActorKind.init(rawValue:)),
        let action = row["action"]?.string.flatMap(AuditAction.init(rawValue:)),
        let targetType = row["target_type"]?.string,
        let targetID = row["target_id"]?.string
      else { throw V2DataError.invalidRow("audit_events") }
      return AuditEvent(
        id: id,
        occurredAt: Date(timeIntervalSince1970: occurred),
        actorKind: actor,
        action: action,
        targetType: targetType,
        targetID: targetID,
        reason: row["reason"]?.string,
        relatedEventID: row["related_event_id"]?.string.flatMap(UUID.init(uuidString:))
      )
    }
  }

  private func appendAudit(_ event: AuditEvent) throws {
    try connection.execute(
      """
      INSERT INTO audit_events(
        id, occurred_at, actor_kind, action, target_type, target_id,
        reason, related_event_id
      ) VALUES (?,?,?,?,?,?,?,?)
      """,
      bindings: [
        .text(event.id.uuidString.lowercased()),
        .real(event.occurredAt.timeIntervalSince1970),
        .text(event.actorKind.rawValue),
        .text(event.action.rawValue),
        .text(event.targetType),
        .text(event.targetID),
        event.reason.map(SQLiteValue.text) ?? .null,
        event.relatedEventID.map { .text($0.uuidString.lowercased()) } ?? .null,
      ]
    )
  }

  private static func invoiceIssueLines(
    invoice: Invoice,
    accounts: InvoiceIssueAccounts,
    counterparty: String
  ) throws -> [JournalLine] {
    var lines = [
      try JournalLine(
        accountID: accounts.receivableAccountID,
        side: .debit,
        amount: invoice.total(),
        counterparty: counterparty
      )
    ]
    for summary in try invoice.taxSummaries() {
      lines.append(
        try JournalLine(
          accountID: accounts.revenueAccountID,
          side: .credit,
          amount: summary.grossAmount,
          taxRate: summary.taxRate,
          invoiceStatus: invoice.issuerRegistrationStatus,
          roundingUnit: .invoice,
          counterparty: counterparty,
          memo: "税抜\(summary.netAmount.yen) 税\(summary.taxAmount.yen)"
        )
      )
    }
    return lines
  }

  private static func appendJournalLine(
    to lines: inout [JournalLine],
    accountID: UUID,
    side: PostingSide,
    amount: Money
  ) throws {
    guard amount.yen > 0 else { return }
    lines.append(try JournalLine(accountID: accountID, side: side, amount: amount))
  }

  public func enqueue(_ job: JobRecord) throws {
    try connection.execute(
      """
      INSERT INTO jobs(
        id, idempotency_key, kind, state, progress_basis_points,
        checkpoint, failure_reason, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(idempotency_key) DO NOTHING
      """,
      bindings: [
        .text(job.id.uuidString.lowercased()),
        .text(job.idempotencyKey),
        .text(job.kind.rawValue),
        .text(job.state.rawValue),
        .integer(Int64(job.progressBasisPoints)),
        job.checkpoint.map(SQLiteValue.text) ?? .null,
        job.failureReason.map(SQLiteValue.text) ?? .null,
        .real(job.createdAt.timeIntervalSince1970),
        .real(job.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func jobs() throws -> [JobRecord] {
    try connection.query(
      """
      SELECT id, idempotency_key, kind, state, progress_basis_points,
             checkpoint, failure_reason, created_at, updated_at
      FROM jobs ORDER BY created_at, id
      """
    ).compactMap { row in
      guard
        let idText = row["id"]?.string,
        let id = UUID(uuidString: idText),
        let idempotencyKey = row["idempotency_key"]?.string,
        let kindText = row["kind"]?.string,
        let kind = BackgroundJobKind(rawValue: kindText),
        let stateText = row["state"]?.string,
        let state = BackgroundJobState(rawValue: stateText),
        let progress = row["progress_basis_points"]?.int64,
        let created = row["created_at"]?.double,
        let updated = row["updated_at"]?.double
      else {
        return nil
      }
      return JobRecord(
        id: id,
        idempotencyKey: idempotencyKey,
        kind: kind,
        state: state,
        progressBasisPoints: Int(progress),
        checkpoint: row["checkpoint"]?.string,
        failureReason: row["failure_reason"]?.string,
        createdAt: Date(timeIntervalSince1970: created),
        updatedAt: Date(timeIntervalSince1970: updated)
      )
    }
  }

  public func updateJob(
    id: UUID,
    state: BackgroundJobState,
    progressBasisPoints: Int,
    checkpoint: String?,
    failureReason: String? = nil,
    at date: Date
  ) throws {
    guard (0...10_000).contains(progressBasisPoints) else {
      throw V2JobError.invalidProgress
    }
    guard
      let currentText = try connection.query(
        "SELECT state FROM jobs WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).first?["state"]?.string,
      let current = BackgroundJobState(rawValue: currentText)
    else {
      throw RepositoryError.notFound
    }
    guard
      V2JobError.allowedTransitions[current, default: []].contains(state)
        || current == state
    else {
      throw V2JobError.invalidTransition(from: current, to: state)
    }
    try connection.execute(
      """
      UPDATE jobs
      SET state = ?, progress_basis_points = ?, checkpoint = ?,
          failure_reason = ?, updated_at = ?
      WHERE id = ?
      """,
      bindings: [
        .text(state.rawValue),
        .integer(Int64(progressBasisPoints)),
        checkpoint.map(SQLiteValue.text) ?? .null,
        failureReason.map(SQLiteValue.text) ?? .null,
        .real(date.timeIntervalSince1970),
        .text(id.uuidString.lowercased()),
      ]
    )
  }

  public func resumableJobs() throws -> [JobRecord] {
    try jobs().filter { $0.state == .queued || $0.state == .running }
  }

  public func diagnose(createdAt: Date = Date()) throws -> DiagnosticReport {
    var findings: [DiagnosticFinding] = []
    let integrity =
      try connection.query("PRAGMA integrity_check")
      .first?.values.first?.string ?? "unknown"
    if integrity != "ok" {
      findings.append(
        DiagnosticFinding(
          severity: .error,
          code: "database.integrity",
          title: "データベース整合性",
          detail: integrity
        )
      )
    }

    let unbalanced =
      try connection.scalarInt(
        """
        SELECT COUNT(*) FROM (
          SELECT journal_entry_id
          FROM journal_lines
          GROUP BY journal_entry_id
          HAVING SUM(CASE WHEN side = 'debit' THEN amount_yen ELSE -amount_yen END) <> 0
        )
        """
      ) ?? 0
    if unbalanced > 0 {
      findings.append(
        DiagnosticFinding(
          severity: .error,
          code: "journal.unbalanced",
          title: "貸借不一致",
          detail: "借方と貸方が一致しない仕訳があります。自動修復は行いません。",
          affectedRecordCount: Int(unbalanced)
        )
      )
    }

    let interrupted =
      try connection.scalarInt("SELECT COUNT(*) FROM jobs WHERE state = 'running'") ?? 0
    if interrupted > 0 {
      findings.append(
        DiagnosticFinding(
          severity: .warning,
          code: "jobs.interrupted",
          title: "中断されたバックグラウンド処理",
          detail: "前回終了時に実行中だった処理を、保存済みチェックポイントから待機状態へ戻せます。",
          affectedRecordCount: Int(interrupted),
          repairKind: "requeue-interrupted-jobs"
        )
      )
    }

    let names = try tableNames()
    var counts: [String: Int] = [:]
    for name in names {
      counts[name] = Int(try connection.scalarInt("SELECT COUNT(*) FROM \(name)") ?? 0)
    }
    return DiagnosticReport(
      createdAt: createdAt,
      findings: findings,
      tableRowCounts: counts,
      evidenceChecked: counts["evidence_documents"] ?? 0
    )
  }

  public func makeRepairPlan(
    from report: DiagnosticReport,
    backupURL: URL,
    createdAt: Date = Date()
  ) -> RepairPlan {
    let repairable = report.findings.filter { $0.repairKind != nil }
    return RepairPlan(
      createdAt: createdAt,
      findingIDs: repairable.map(\.id),
      backupURL: backupURL,
      changes: repairable.compactMap { finding in
        guard let kind = finding.repairKind else { return nil }
        return RepairChange(
          kind: kind,
          summary: finding.detail,
          affectedRecordCount: finding.affectedRecordCount ?? 0
        )
      }
    )
  }

  public func apply(
    _ plan: RepairPlan,
    fileManager: FileManager = .default,
    at date: Date = Date()
  ) throws -> RepairPlan {
    guard plan.state == .previewed else { throw V2RepairError.planAlreadyApplied }
    guard fileManager.fileExists(atPath: plan.backupURL.path) else {
      throw V2RepairError.backupNotFound
    }
    let supportedKinds: Set<String> = ["requeue-interrupted-jobs"]
    guard plan.changes.allSatisfy({ supportedKinds.contains($0.kind) }) else {
      throw V2RepairError.unsupportedRepair
    }
    try connection.transaction {
      for change in plan.changes where change.kind == "requeue-interrupted-jobs" {
        try connection.execute(
          """
          UPDATE jobs
          SET state = 'queued',
              failure_reason = '前回のアプリ終了後に再開待ちへ戻しました',
              updated_at = ?
          WHERE state = 'running'
          """,
          bindings: [.real(date.timeIntervalSince1970)]
        )
      }
    }
    var applied = plan
    applied.state = .applied
    return applied
  }

  private static let allowedTableNames: Set<String> = [
    "storage_metadata", "business_profiles", "fiscal_years", "accounts",
    "journal_entries", "journal_lines", "evidence_documents", "counterparties",
    "invoices", "invoice_items", "settlements", "closing_decisions",
    "ocr_candidates", "evidence_links", "journal_templates", "journal_rules",
    "recurring_journals", "journal_candidates", "import_candidates",
    "import_candidate_warnings", "match_candidates", "audit_events", "jobs",
    "counterparty_roles",
  ]

  private static func decodeEvidence(_ row: SQLiteRow) throws -> EvidenceDocument {
    guard
      let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
      let relativePath = row["original_relative_path"]?.string,
      let filename = row["original_filename"]?.string,
      let sha256 = row["sha256"]?.string,
      let byteCount = row["byte_count"]?.int64,
      let mimeType = row["mime_type"]?.string,
      let acquiredAt = row["acquired_at"]?.double,
      let origin = row["origin"]?.string.flatMap(EvidenceOrigin.init(rawValue:)),
      let state = row["review_state"]?.string.flatMap(EvidenceState.init(rawValue:)),
      let electronic = row["electronic_transaction"]?.int64,
      let createdAt = row["created_at"]?.double,
      let updatedAt = row["updated_at"]?.double
    else { throw V2DataError.invalidRow("evidence_documents") }
    return EvidenceDocument(
      metadata: EntityMetadata(
        id: id,
        createdAt: Date(timeIntervalSince1970: createdAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
      ),
      originalSHA256: sha256,
      originalRelativePath: relativePath,
      originalFilename: filename,
      mimeType: mimeType,
      byteCount: byteCount,
      acquiredAt: Date(timeIntervalSince1970: acquiredAt),
      origin: origin,
      state: state,
      transactionDate: row["transaction_date"]?.double.map(Date.init(timeIntervalSince1970:)),
      amount: row["amount_yen"]?.int64.map(Money.init(yen:)),
      counterparty: row["counterparty_name"]?.string,
      electronicTransaction: electronic != 0
    )
  }

  private static func decodeJournalCandidate(_ row: SQLiteRow) throws -> JournalCandidateV2 {
    guard
      let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
      let key = row["idempotency_key"]?.string,
      let sourceKind = row["source_kind"]?.string,
      let transactionDate = row["transaction_date"]?.double,
      let description = row["description"]?.string,
      let amount = row["amount_yen"]?.int64,
      let debit = row["debit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
      let credit = row["credit_account_id"]?.string.flatMap(UUID.init(uuidString:)),
      let tax = row["tax_rate"]?.string.flatMap(TaxRate.init(rawValue:)),
      let invoice = row["invoice_registration_status"]?.string.flatMap(
        InvoiceRegistrationStatus.init(rawValue:)),
      let confidence = row["confidence_basis_points"]?.int64,
      let explanation = row["explanation"]?.string,
      let state = row["state"]?.string.flatMap(JournalCandidateStateV2.init(rawValue:)),
      let created = row["created_at"]?.double,
      let updated = row["updated_at"]?.double
    else { throw V2DataError.invalidRow("journal_candidates") }
    return JournalCandidateV2(
      id: id,
      idempotencyKey: key,
      sourceKind: sourceKind,
      sourceID: row["source_id"]?.string.flatMap(UUID.init(uuidString:)),
      transactionDate: Date(timeIntervalSince1970: transactionDate),
      description: description,
      amountYen: amount,
      debitAccountID: debit,
      creditAccountID: credit,
      taxRate: tax,
      invoiceStatus: invoice,
      confidenceBasisPoints: Int(confidence),
      explanation: explanation,
      state: state,
      journalEntryID: row["journal_entry_id"]?.string.flatMap(UUID.init(uuidString:)),
      createdAt: Date(timeIntervalSince1970: created),
      updatedAt: Date(timeIntervalSince1970: updated)
    )
  }

  private static func createSchemaIfNeeded(_ connection: SQLiteConnection) throws {
    let version = Int(try connection.scalarInt("PRAGMA user_version") ?? 0)
    guard version == 0 || version == schemaVersion else {
      throw V2StorageError.invalidGeneration(found: version)
    }
    guard version == 0 else { return }
    try connection.transaction {
      try connection.execute(
        """
        CREATE TABLE storage_metadata(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE fiscal_years(
          id TEXT PRIMARY KEY,
          calendar_year INTEGER NOT NULL UNIQUE,
          status TEXT NOT NULL,
          tax_rule_set_id TEXT NOT NULL,
          form_rule_set_id TEXT,
          locked_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE business_profiles(
          id TEXT PRIMARY KEY,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          owner_name TEXT NOT NULL,
          trade_name TEXT NOT NULL,
          postal_address TEXT NOT NULL DEFAULT '',
          tax_address TEXT NOT NULL DEFAULT '',
          tax_office TEXT NOT NULL DEFAULT '',
          tax_office_code TEXT NOT NULL DEFAULT '',
          e_tax_user_id TEXT NOT NULL DEFAULT '',
          industry TEXT NOT NULL DEFAULT '',
          opened_on REAL,
          blue_return_approved INTEGER NOT NULL,
          consumption_tax_status TEXT NOT NULL,
          invoice_registration_status TEXT NOT NULL,
          invoice_registration_number TEXT,
          invoice_registered_on REAL,
          invoice_cancelled_on REAL,
          bookkeeping_style TEXT NOT NULL,
          tax_accounting_method TEXT NOT NULL,
          rounding_rule TEXT NOT NULL,
          default_tax_rate TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE accounts(
          id TEXT PRIMARY KEY,
          code TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          category TEXT NOT NULL,
          normal_balance TEXT NOT NULL,
          default_tax_rate TEXT NOT NULL,
          statement_section TEXT NOT NULL,
          display_order INTEGER NOT NULL,
          is_active INTEGER NOT NULL,
          is_system INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE journal_entries(
          id TEXT PRIMARY KEY,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          transaction_date REAL NOT NULL,
          description TEXT NOT NULL,
          kind TEXT NOT NULL,
          status TEXT NOT NULL,
          source_entry_id TEXT,
          reason TEXT,
          posted_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE journal_lines(
          id TEXT PRIMARY KEY,
          journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL,
          account_id TEXT NOT NULL REFERENCES accounts(id),
          sub_account_id TEXT,
          side TEXT NOT NULL,
          amount_yen INTEGER NOT NULL,
          tax_rate TEXT,
          invoice_registration_status TEXT,
          deductible_basis_points INTEGER NOT NULL,
          rounding_unit TEXT NOT NULL,
          counterparty TEXT NOT NULL DEFAULT '',
          memo TEXT NOT NULL DEFAULT '',
          UNIQUE(journal_entry_id, sequence)
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE evidence_documents(
          id TEXT PRIMARY KEY,
          fiscal_year_id TEXT REFERENCES fiscal_years(id),
          original_relative_path TEXT NOT NULL UNIQUE,
          original_filename TEXT NOT NULL,
          sha256 TEXT NOT NULL UNIQUE,
          byte_count INTEGER NOT NULL,
          mime_type TEXT NOT NULL,
          acquired_at REAL NOT NULL,
          origin TEXT NOT NULL,
          transaction_date REAL,
          amount_yen INTEGER,
          counterparty_name TEXT,
          review_state TEXT NOT NULL,
          electronic_transaction INTEGER NOT NULL,
          ocr_snapshot_json TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE ocr_candidates(
          id TEXT PRIMARY KEY,
          evidence_id TEXT NOT NULL REFERENCES evidence_documents(id) ON DELETE CASCADE,
          field TEXT NOT NULL,
          raw_value TEXT NOT NULL,
          confidence REAL NOT NULL,
          corrected_value TEXT,
          corrected_at REAL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE evidence_links(
          id TEXT PRIMARY KEY,
          evidence_id TEXT NOT NULL REFERENCES evidence_documents(id),
          journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id),
          linked_at REAL NOT NULL,
          UNIQUE(evidence_id, journal_entry_id)
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE import_candidates(
          id TEXT PRIMARY KEY,
          source_kind TEXT NOT NULL,
          source_fingerprint TEXT NOT NULL UNIQUE,
          occurred_at REAL,
          amount_yen INTEGER,
          description TEXT NOT NULL,
          state TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE import_candidate_warnings(
          import_candidate_id TEXT NOT NULL REFERENCES import_candidates(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL,
          warning TEXT NOT NULL,
          PRIMARY KEY(import_candidate_id, sequence)
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE journal_templates(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          default_description TEXT NOT NULL,
          debit_account_id TEXT NOT NULL REFERENCES accounts(id),
          credit_account_id TEXT NOT NULL REFERENCES accounts(id),
          tax_rate TEXT NOT NULL,
          invoice_registration_status TEXT NOT NULL,
          is_active INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE journal_rules(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description_contains TEXT NOT NULL,
          debit_account_id TEXT NOT NULL REFERENCES accounts(id),
          credit_account_id TEXT NOT NULL REFERENCES accounts(id),
          tax_rate TEXT NOT NULL,
          priority INTEGER NOT NULL,
          is_active INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE recurring_journals(
          id TEXT PRIMARY KEY,
          template_id TEXT NOT NULL REFERENCES journal_templates(id),
          frequency TEXT NOT NULL,
          day_of_month INTEGER NOT NULL,
          amount_yen INTEGER NOT NULL,
          next_run_at REAL NOT NULL,
          is_active INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE journal_candidates(
          id TEXT PRIMARY KEY,
          idempotency_key TEXT NOT NULL UNIQUE,
          source_kind TEXT NOT NULL,
          source_id TEXT,
          transaction_date REAL NOT NULL,
          description TEXT NOT NULL,
          amount_yen INTEGER NOT NULL,
          debit_account_id TEXT NOT NULL REFERENCES accounts(id),
          credit_account_id TEXT NOT NULL REFERENCES accounts(id),
          tax_rate TEXT NOT NULL,
          invoice_registration_status TEXT NOT NULL,
          confidence_basis_points INTEGER NOT NULL,
          explanation TEXT NOT NULL,
          state TEXT NOT NULL,
          journal_entry_id TEXT REFERENCES journal_entries(id),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE match_candidates(
          id TEXT PRIMARY KEY,
          idempotency_key TEXT NOT NULL UNIQUE,
          import_candidate_id TEXT NOT NULL REFERENCES import_candidates(id),
          evidence_id TEXT NOT NULL REFERENCES evidence_documents(id),
          journal_candidate_id TEXT REFERENCES journal_candidates(id),
          confidence_basis_points INTEGER NOT NULL,
          explanation TEXT NOT NULL,
          state TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE counterparties(
          id TEXT PRIMARY KEY,
          code TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          postal_code TEXT NOT NULL,
          address TEXT NOT NULL,
          contact_name TEXT NOT NULL,
          email TEXT NOT NULL,
          invoice_registration_status TEXT NOT NULL,
          invoice_registration_number TEXT,
          payment_terms_days INTEGER NOT NULL,
          withholding_default_enabled INTEGER NOT NULL,
          is_active INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE counterparty_roles(
          counterparty_id TEXT NOT NULL REFERENCES counterparties(id) ON DELETE CASCADE,
          role TEXT NOT NULL,
          PRIMARY KEY(counterparty_id, role)
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE invoices(
          id TEXT PRIMARY KEY,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          counterparty_id TEXT NOT NULL REFERENCES counterparties(id),
          number TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          issue_date REAL NOT NULL,
          due_date REAL NOT NULL,
          subject TEXT NOT NULL,
          status TEXT NOT NULL,
          rounding_rule TEXT NOT NULL,
          issuer_name TEXT NOT NULL,
          issuer_address TEXT NOT NULL,
          issuer_registration_status TEXT NOT NULL,
          issuer_registration_number TEXT,
          source_invoice_id TEXT REFERENCES invoices(id),
          reason TEXT,
          journal_entry_id TEXT REFERENCES journal_entries(id),
          evidence_id TEXT REFERENCES evidence_documents(id),
          subtotal_yen INTEGER NOT NULL,
          tax_yen INTEGER NOT NULL,
          total_yen INTEGER NOT NULL,
          outstanding_yen INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE invoice_items(
          id TEXT PRIMARY KEY,
          invoice_id TEXT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL,
          description TEXT NOT NULL,
          quantity INTEGER NOT NULL,
          unit_price_yen INTEGER NOT NULL,
          tax_rate TEXT NOT NULL,
          amount_yen INTEGER NOT NULL,
          UNIQUE(invoice_id, sequence)
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE settlements(
          id TEXT PRIMARY KEY,
          invoice_id TEXT NOT NULL REFERENCES invoices(id),
          settled_at REAL NOT NULL,
          applied_amount_yen INTEGER NOT NULL,
          cash_received_yen INTEGER NOT NULL,
          fee_yen INTEGER NOT NULL DEFAULT 0,
          withholding_yen INTEGER NOT NULL DEFAULT 0,
          discount_yen INTEGER NOT NULL DEFAULT 0,
          overpayment_yen INTEGER NOT NULL DEFAULT 0,
          source_transaction_id TEXT,
          journal_entry_id TEXT REFERENCES journal_entries(id),
          created_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE closing_decisions(
          id TEXT PRIMARY KEY,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          decision_type TEXT NOT NULL,
          status TEXT NOT NULL,
          amount_yen INTEGER,
          rationale TEXT NOT NULL,
          source_snapshot_json TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE audit_events(
          id TEXT PRIMARY KEY,
          occurred_at REAL NOT NULL,
          actor_kind TEXT NOT NULL,
          action TEXT NOT NULL,
          target_type TEXT NOT NULL,
          target_id TEXT NOT NULL,
          reason TEXT,
          related_event_id TEXT,
          before_hash TEXT,
          after_hash TEXT
        )
        """
      )
      try connection.execute(
        """
        CREATE TABLE jobs(
          id TEXT PRIMARY KEY,
          idempotency_key TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          state TEXT NOT NULL,
          progress_basis_points INTEGER NOT NULL,
          checkpoint TEXT,
          failure_reason TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """
      )
      try connection.execute(
        "INSERT INTO storage_metadata(key, value) VALUES (?, ?)",
        bindings: [.text("storage_generation"), .text("2")]
      )
      try connection.execute(
        "INSERT INTO storage_metadata(key, value) VALUES (?, ?)",
        bindings: [.text("backup_family"), .text("blueprint-v2")]
      )
      try connection.execute("PRAGMA user_version = \(schemaVersion)")
    }
  }
}

public enum V2RepairError: Error, Equatable, Sendable {
  case backupNotFound
  case planAlreadyApplied
  case unsupportedRepair
}

public enum V2DataError: Error, Equatable, Sendable {
  case invalidRow(String)
}

public enum V2JobError: Error, Equatable, Sendable {
  case invalidProgress
  case invalidTransition(from: BackgroundJobState, to: BackgroundJobState)

  fileprivate static let allowedTransitions: [BackgroundJobState: Set<BackgroundJobState>] = [
    .queued: [.running, .cancelled, .failed],
    .running: [.queued, .succeeded, .failed, .cancelled],
    .failed: [.queued],
    .succeeded: [],
    .cancelled: [],
  ]
}

extension V2Database: V2CoreRepository {}
extension V2Database: V2AutomationRepository {}
