import BlueprintBilling
import BlueprintDomain
import Foundation

public final class SQLiteBillingRepository: BillingRepository, @unchecked Sendable {
  private let connection: SQLiteConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveCounterparty(_ counterparty: Counterparty) throws {
    try connection.execute(
      """
      INSERT INTO counterparties(
          id, code, display_name, roles_json, is_active, payload_json, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          code = excluded.code,
          display_name = excluded.display_name,
          roles_json = excluded.roles_json,
          is_active = excluded.is_active,
          payload_json = excluded.payload_json,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(counterparty.id.billingDB), .text(counterparty.code),
        .text(counterparty.displayName),
        .text(try jsonString(Array(counterparty.roles).sorted { $0.rawValue < $1.rawValue })),
        .integer(counterparty.isActive ? 1 : 0), .text(try jsonString(counterparty)),
        .real(counterparty.metadata.createdAt.timeIntervalSince1970),
        .real(counterparty.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func counterparties(includeInactive: Bool) throws -> [Counterparty] {
    let sql =
      includeInactive
      ? "SELECT payload_json FROM counterparties ORDER BY code"
      : "SELECT payload_json FROM counterparties WHERE is_active = 1 ORDER BY code"
    return try connection.query(sql).map { try decode(Counterparty.self, row: $0) }
  }

  public func saveInvoice(_ invoice: Invoice) throws {
    do {
      try connection.execute(
        """
        INSERT INTO invoices(
            id, fiscal_year_id, counterparty_id, number, issue_date, due_date, status,
            kind, source_invoice_id, journal_entry_id, evidence_id, payload_json,
            created_at, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            number = excluded.number,
            issue_date = excluded.issue_date,
            due_date = excluded.due_date,
            status = excluded.status,
            kind = excluded.kind,
            source_invoice_id = excluded.source_invoice_id,
            journal_entry_id = excluded.journal_entry_id,
            evidence_id = excluded.evidence_id,
            payload_json = excluded.payload_json,
            updated_at = excluded.updated_at
        """,
        bindings: [
          .text(invoice.id.billingDB), .text(invoice.fiscalYearID.billingDB),
          .text(invoice.counterpartyID.billingDB), .text(invoice.number),
          .real(invoice.issueDate.timeIntervalSince1970),
          .real(invoice.dueDate.timeIntervalSince1970),
          .text(invoice.status.rawValue), .text(invoice.kind.rawValue),
          invoice.sourceInvoiceID.map { .text($0.billingDB) } ?? .null,
          invoice.journalEntryID.map { .text($0.billingDB) } ?? .null,
          invoice.evidenceID.map { .text($0.billingDB) } ?? .null,
          .text(try jsonString(invoice)),
          .real(invoice.metadata.createdAt.timeIntervalSince1970),
          .real(invoice.metadata.updatedAt.timeIntervalSince1970),
        ]
      )
    } catch let error as SQLiteFailure where error.message.contains("UNIQUE constraint failed") {
      throw BillingError.duplicateNumber
    }
  }

  public func invoice(id: EntityID) throws -> Invoice? {
    try connection.query(
      "SELECT payload_json FROM invoices WHERE id = ?",
      bindings: [.text(id.billingDB)]
    ).first.map { try decode(Invoice.self, row: $0) }
  }

  public func invoice(number: String) throws -> Invoice? {
    try connection.query(
      "SELECT payload_json FROM invoices WHERE number = ?",
      bindings: [.text(number)]
    ).first.map { try decode(Invoice.self, row: $0) }
  }

  public func invoices(_ search: BillingSearch) throws -> [Invoice] {
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []
    if let id = search.fiscalYearID {
      clauses.append("fiscal_year_id = ?")
      bindings.append(.text(id.billingDB))
    }
    if let id = search.counterpartyID {
      clauses.append("counterparty_id = ?")
      bindings.append(.text(id.billingDB))
    }
    if !search.invoiceStatuses.isEmpty {
      let statuses = search.invoiceStatuses.sorted { $0.rawValue < $1.rawValue }
      clauses.append(
        "status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ",")))"
      )
      bindings += statuses.map { .text($0.rawValue) }
    }
    if let date = search.overdueAsOf {
      clauses.append("due_date < ?")
      bindings.append(.real(date.timeIntervalSince1970))
      clauses.append("status IN ('issued','partiallyPaid','overdue')")
    }
    let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
    return try connection.query(
      "SELECT payload_json FROM invoices \(whereClause) ORDER BY issue_date DESC, number DESC",
      bindings: bindings
    ).map { try decode(Invoice.self, row: $0) }
  }

  public func appendReissue(_ reissue: InvoiceReissue) throws {
    try connection.execute(
      """
      INSERT INTO invoice_reissues(
          id, invoice_id, sequence, issued_at, reason, evidence_id, payload_json
      ) VALUES (?,?,?,?,?,?,?)
      """,
      bindings: [
        .text(reissue.id.billingDB), .text(reissue.invoiceID.billingDB),
        .integer(Int64(reissue.sequence)), .real(reissue.issuedAt.timeIntervalSince1970),
        .text(reissue.reason), .text(reissue.evidenceID.billingDB),
        .text(try jsonString(reissue)),
      ]
    )
  }

  public func reissues(invoiceID: EntityID) throws -> [InvoiceReissue] {
    try connection.query(
      "SELECT payload_json FROM invoice_reissues WHERE invoice_id = ? ORDER BY sequence",
      bindings: [.text(invoiceID.billingDB)]
    ).map { try decode(InvoiceReissue.self, row: $0) }
  }

  public func saveVendorBill(_ bill: VendorBill) throws {
    try connection.execute(
      """
      INSERT INTO vendor_bills(
          id, fiscal_year_id, vendor_id, reference_number, issue_date, due_date,
          status, journal_entry_id, evidence_id, payload_json, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          reference_number = excluded.reference_number,
          issue_date = excluded.issue_date,
          due_date = excluded.due_date,
          status = excluded.status,
          journal_entry_id = excluded.journal_entry_id,
          evidence_id = excluded.evidence_id,
          payload_json = excluded.payload_json,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(bill.id.billingDB), .text(bill.fiscalYearID.billingDB),
        .text(bill.vendorID.billingDB), .text(bill.referenceNumber),
        .real(bill.issueDate.timeIntervalSince1970), .real(bill.dueDate.timeIntervalSince1970),
        .text(bill.status.rawValue), bill.journalEntryID.map { .text($0.billingDB) } ?? .null,
        bill.evidenceID.map { .text($0.billingDB) } ?? .null,
        .text(try jsonString(bill)), .real(bill.metadata.createdAt.timeIntervalSince1970),
        .real(bill.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func vendorBill(id: EntityID) throws -> VendorBill? {
    try connection.query(
      "SELECT payload_json FROM vendor_bills WHERE id = ?",
      bindings: [.text(id.billingDB)]
    ).first.map { try decode(VendorBill.self, row: $0) }
  }

  public func vendorBills(_ search: BillingSearch) throws -> [VendorBill] {
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []
    if let id = search.fiscalYearID {
      clauses.append("fiscal_year_id = ?")
      bindings.append(.text(id.billingDB))
    }
    if let id = search.counterpartyID {
      clauses.append("vendor_id = ?")
      bindings.append(.text(id.billingDB))
    }
    if !search.vendorBillStatuses.isEmpty {
      let statuses = search.vendorBillStatuses.sorted { $0.rawValue < $1.rawValue }
      clauses.append(
        "status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ",")))"
      )
      bindings += statuses.map { .text($0.rawValue) }
    }
    if let date = search.overdueAsOf {
      clauses.append("due_date < ?")
      bindings.append(.real(date.timeIntervalSince1970))
      clauses.append("status IN ('confirmed','partiallyPaid')")
    }
    let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
    return try connection.query(
      "SELECT payload_json FROM vendor_bills \(whereClause) ORDER BY issue_date DESC, reference_number DESC",
      bindings: bindings
    ).map { try decode(VendorBill.self, row: $0) }
  }

  private func jsonString<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func decode<T: Decodable>(_ type: T.Type, row: SQLiteRow) throws -> T {
    guard case .text(let value)? = row["payload_json"] else {
      throw RepositoryError.invalidData("Missing billing payload")
    }
    return try decoder.decode(type, from: Data(value.utf8))
  }
}

extension UUID {
  fileprivate var billingDB: String { uuidString.lowercased() }
}
