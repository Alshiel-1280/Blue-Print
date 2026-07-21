import BlueprintDomain
import Foundation

public final class SQLiteJournalRepository: JournalRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveDraft(_ entry: JournalEntry) throws {
    if let existing = try fetch(id: entry.id), existing.status == .posted {
      throw JournalError.cannotModifyPostedEntry
    }
    guard entry.status == .draft || entry.status == .pendingReview else {
      throw JournalError.cannotModifyPostedEntry
    }
    try connection.transaction { try persist(entry) }
  }

  public func post(id: EntityID, fiscalYear: FiscalYear, at date: Date) throws {
    try connection.transaction {
      guard var entry = try fetch(id: id) else { throw RepositoryError.notFound }
      try entry.post(for: fiscalYear, at: date)
      try persist(entry)
    }
  }

  public func fetch(id: EntityID) throws -> JournalEntry? {
    guard
      let row = try connection.query(
        "SELECT * FROM journal_entries WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).first
    else { return nil }
    return try decodeEntry(row: row)
  }

  public func search(_ query: JournalSearch) throws -> [JournalEntry] {
    var clauses = ["e.fiscal_year_id = ?"]
    var bindings: [SQLiteValue] = [.text(query.fiscalYearID.uuidString.lowercased())]

    if let range = query.dateRange {
      clauses.append("e.transaction_date BETWEEN ? AND ?")
      bindings += [
        .real(range.lowerBound.timeIntervalSince1970),
        .real(range.upperBound.timeIntervalSince1970),
      ]
    }
    if !query.statuses.isEmpty {
      let statuses = query.statuses.sorted { $0.rawValue < $1.rawValue }
      clauses.append(
        "e.status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ",")))")
      bindings += statuses.map { .text($0.rawValue) }
    }
    if let accountID = query.accountID {
      clauses.append(
        "EXISTS (SELECT 1 FROM journal_lines a WHERE a.entry_id = e.id AND a.account_id = ?)")
      bindings.append(.text(accountID.uuidString.lowercased()))
    }
    if let minimum = query.minimumAmount {
      clauses.append(
        "EXISTS (SELECT 1 FROM journal_lines n WHERE n.entry_id = e.id AND n.amount_yen >= ?)")
      bindings.append(.integer(minimum.yen))
    }
    if let maximum = query.maximumAmount {
      clauses.append(
        "EXISTS (SELECT 1 FROM journal_lines x WHERE x.entry_id = e.id AND x.amount_yen <= ?)")
      bindings.append(.integer(maximum.yen))
    }
    if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      clauses.append(
        "(e.description LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM journal_lines t WHERE t.entry_id = e.id AND (t.counterparty LIKE ? ESCAPE '\\' OR t.memo LIKE ? ESCAPE '\\')))"
      )
      let pattern = "%\(escapeLike(text))%"
      bindings += [.text(pattern), .text(pattern), .text(pattern)]
    }

    let rows = try connection.query(
      "SELECT e.* FROM journal_entries e WHERE \(clauses.joined(separator: " AND ")) ORDER BY e.transaction_date DESC, e.created_at DESC",
      bindings: bindings
    )
    return try rows.map(decodeEntry(row:))
  }

  public func delete(id: EntityID) throws {
    try connection.transaction {
      guard let entry = try fetch(id: id) else { throw RepositoryError.notFound }
      guard entry.status == .draft || entry.status == .pendingReview else {
        throw RepositoryError.physicalDeletionForbidden
      }
      try connection.execute(
        "DELETE FROM journal_entries WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      )
    }
  }

  func persist(_ entry: JournalEntry) throws {
    let isNew = try connection.query(
      "SELECT id FROM journal_entries WHERE id = ?",
      bindings: [.text(entry.id.uuidString.lowercased())]
    ).isEmpty
    try connection.execute(
      """
      INSERT INTO journal_entries (
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
    guard isNew || entry.status == .draft || entry.status == .pendingReview else { return }
    if !isNew {
      try connection.execute(
        "DELETE FROM journal_lines WHERE entry_id = ?",
        bindings: [.text(entry.id.uuidString.lowercased())]
      )
    }
    for (index, line) in entry.lines.enumerated() {
      try connection.execute(
        """
        INSERT INTO journal_lines (
            id, entry_id, account_id, sub_account_id, side, amount_yen,
            tax_rate, invoice_status, deductible_basis_points, rounding_unit,
            counterparty, memo, line_order
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        bindings: [
          .text(line.id.uuidString.lowercased()),
          .text(entry.id.uuidString.lowercased()),
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
          .integer(Int64(index)),
        ]
      )
    }
  }

  private func decodeEntry(row: SQLiteRow) throws -> JournalEntry {
    let id = try uuid(row, "id")
    let lineRows = try connection.query(
      "SELECT * FROM journal_lines WHERE entry_id = ? ORDER BY line_order",
      bindings: [.text(id.uuidString.lowercased())]
    )
    let lines = try lineRows.map { line in
      try JournalLine(
        id: uuid(line, "id"),
        accountID: uuid(line, "account_id"),
        subAccountID: optionalUUID(line, "sub_account_id"),
        side: enumValue(line, "side"),
        amount: Money(yen: integer(line, "amount_yen")),
        taxRate: enumValue(line, "tax_rate"),
        invoiceStatus: enumValue(line, "invoice_status"),
        deductibleBasisPoints: Int(try integer(line, "deductible_basis_points")),
        roundingUnit: enumValue(line, "rounding_unit"),
        counterparty: text(line, "counterparty"),
        memo: text(line, "memo")
      )
    }
    return JournalEntry(
      metadata: EntityMetadata(
        id: id,
        createdAt: try date(row, "created_at"),
        updatedAt: try date(row, "updated_at")
      ),
      fiscalYearID: try uuid(row, "fiscal_year_id"),
      transactionDate: try date(row, "transaction_date"),
      description: try text(row, "description"),
      kind: try enumValue(row, "kind"),
      status: try enumValue(row, "status"),
      lines: lines,
      sourceEntryID: try optionalUUID(row, "source_entry_id"),
      reason: textIfPresent(row, "reason"),
      postedAt: dateIfPresent(row, "posted_at")
    )
  }

  private func escapeLike(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private func text(_ row: SQLiteRow, _ key: String) throws -> String {
    guard case .text(let value)? = row[key] else {
      throw RepositoryError.invalidData("Expected text for \(key)")
    }
    return value
  }

  private func textIfPresent(_ row: SQLiteRow, _ key: String) -> String? {
    guard case .text(let value)? = row[key] else { return nil }
    return value
  }

  private func integer(_ row: SQLiteRow, _ key: String) throws -> Int64 {
    guard case .integer(let value)? = row[key] else {
      throw RepositoryError.invalidData("Expected integer for \(key)")
    }
    return value
  }

  private func date(_ row: SQLiteRow, _ key: String) throws -> Date {
    guard let value = row[key]?.double else {
      throw RepositoryError.invalidData("Expected date for \(key)")
    }
    return Date(timeIntervalSince1970: value)
  }

  private func dateIfPresent(_ row: SQLiteRow, _ key: String) -> Date? {
    row[key]?.double.map(Date.init(timeIntervalSince1970:))
  }

  private func uuid(_ row: SQLiteRow, _ key: String) throws -> UUID {
    let value = try text(row, key)
    guard let result = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return result
  }

  private func optionalUUID(_ row: SQLiteRow, _ key: String) throws -> UUID? {
    guard let value = textIfPresent(row, key) else { return nil }
    guard let result = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return result
  }

  private func enumValue<T: RawRepresentable>(_ row: SQLiteRow, _ key: String) throws -> T
  where T.RawValue == String {
    let value = try text(row, key)
    guard let result = T(rawValue: value) else {
      throw RepositoryError.invalidData("Invalid value '\(value)' for \(key)")
    }
    return result
  }
}
