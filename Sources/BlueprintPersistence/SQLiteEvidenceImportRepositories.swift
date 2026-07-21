import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import Foundation

public final class SQLiteEvidenceRepository: EvidenceRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func save(_ document: EvidenceDocument) throws {
    try connection.execute(
      """
      INSERT INTO evidence_documents (
          id, original_sha256, original_relative_path, original_filename, mime_type,
          byte_count, acquired_at, origin, state, transaction_date, amount_yen,
          counterparty, electronic_transaction, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          state = excluded.state,
          transaction_date = excluded.transaction_date,
          amount_yen = excluded.amount_yen,
          counterparty = excluded.counterparty,
          electronic_transaction = excluded.electronic_transaction,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(document.id.db), .text(document.originalSHA256),
        .text(document.originalRelativePath), .text(document.originalFilename),
        .text(document.mimeType), .integer(document.byteCount),
        .real(document.acquiredAt.timeIntervalSince1970), .text(document.origin.rawValue),
        .text(document.state.rawValue), document.transactionDate.sqlite,
        document.amount.map { .integer($0.yen) } ?? .null, document.counterparty.sqlite,
        .integer(document.electronicTransaction ? 1 : 0),
        .real(document.metadata.createdAt.timeIntervalSince1970),
        .real(document.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func fetch(id: EntityID) throws -> EvidenceDocument? {
    try connection.query(
      "SELECT * FROM evidence_documents WHERE id = ?",
      bindings: [.text(id.db)]
    ).first.map(decodeDocument)
  }

  public func fetch(sha256: String) throws -> EvidenceDocument? {
    try connection.query(
      "SELECT * FROM evidence_documents WHERE original_sha256 = ?",
      bindings: [.text(sha256)]
    ).first.map(decodeDocument)
  }

  public func search(_ query: EvidenceSearch) throws -> [EvidenceDocument] {
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []
    if let range = query.dateRange {
      clauses.append("transaction_date BETWEEN ? AND ?")
      bindings += [
        .real(range.lowerBound.timeIntervalSince1970),
        .real(range.upperBound.timeIntervalSince1970),
      ]
    }
    if let amount = query.amount {
      clauses.append("amount_yen = ?")
      bindings.append(.integer(amount.yen))
    }
    if let counterparty = query.counterparty, !counterparty.isEmpty {
      clauses.append("counterparty LIKE ?")
      bindings.append(.text("%\(counterparty)%"))
    }
    if !query.states.isEmpty {
      let states = query.states.sorted { $0.rawValue < $1.rawValue }
      clauses.append(
        "state IN (\(Array(repeating: "?", count: states.count).joined(separator: ",")))")
      bindings += states.map { .text($0.rawValue) }
    }
    if query.electronicOnly { clauses.append("electronic_transaction = 1") }
    let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
    return try connection.query(
      "SELECT * FROM evidence_documents \(whereClause) ORDER BY acquired_at DESC, id",
      bindings: bindings
    ).map(decodeDocument)
  }

  public func appendCandidate(_ candidate: OCRCandidate) throws {
    try connection.execute(
      """
      INSERT INTO ocr_candidates (
          id, evidence_id, field, raw_value, confidence, corrected_value, corrected_at
      ) VALUES (?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          corrected_value = excluded.corrected_value,
          corrected_at = excluded.corrected_at
      """,
      bindings: [
        .text(candidate.id.db), .text(candidate.evidenceID.db), .text(candidate.field.rawValue),
        .text(candidate.rawValue), .real(candidate.confidence), candidate.correctedValue.sqlite,
        candidate.correctedAt.sqlite,
      ]
    )
  }

  public func candidates(evidenceID: EntityID) throws -> [OCRCandidate] {
    try connection.query(
      "SELECT * FROM ocr_candidates WHERE evidence_id = ? ORDER BY field, confidence DESC",
      bindings: [.text(evidenceID.db)]
    ).map { row in
      OCRCandidate(
        id: try row.uuid("id"),
        evidenceID: try row.uuid("evidence_id"),
        field: try row.enumeration("field"),
        rawValue: try row.textValue("raw_value"),
        confidence: try row.number("confidence"),
        correctedValue: row.optionalText("corrected_value"),
        correctedAt: row.optionalDate("corrected_at")
      )
    }
  }

  public func link(_ link: EvidenceLink) throws {
    try connection.execute(
      "INSERT OR IGNORE INTO evidence_links(id, evidence_id, journal_entry_id, linked_at) VALUES (?,?,?,?)",
      bindings: [
        .text(link.id.db), .text(link.evidenceID.db), .text(link.journalEntryID.db),
        .real(link.linkedAt.timeIntervalSince1970),
      ]
    )
  }

  public func links(evidenceID: EntityID) throws -> [EvidenceLink] {
    try connection.query(
      "SELECT * FROM evidence_links WHERE evidence_id = ? ORDER BY linked_at",
      bindings: [.text(evidenceID.db)]
    ).map { row in
      EvidenceLink(
        id: try row.uuid("id"),
        evidenceID: try row.uuid("evidence_id"),
        journalEntryID: try row.uuid("journal_entry_id"),
        linkedAt: try row.dateValue("linked_at")
      )
    }
  }

  private func decodeDocument(_ row: SQLiteRow) throws -> EvidenceDocument {
    EvidenceDocument(
      metadata: EntityMetadata(
        id: try row.uuid("id"),
        createdAt: try row.dateValue("created_at"),
        updatedAt: try row.dateValue("updated_at")
      ),
      originalSHA256: try row.textValue("original_sha256"),
      originalRelativePath: try row.textValue("original_relative_path"),
      originalFilename: try row.textValue("original_filename"),
      mimeType: try row.textValue("mime_type"),
      byteCount: try row.integerValue("byte_count"),
      acquiredAt: try row.dateValue("acquired_at"),
      origin: try row.enumeration("origin"),
      state: try row.enumeration("state"),
      transactionDate: row.optionalDate("transaction_date"),
      amount: row["amount_yen"]?.int64.map(Money.init(yen:)),
      counterparty: row.optionalText("counterparty"),
      electronicTransaction: try row.boolean("electronic_transaction")
    )
  }
}

public final class SQLiteImportRepository: ImportRepository, @unchecked Sendable {
  private let connection: SQLiteConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveProfile(_ profile: ImportProfile) throws {
    let mapping = try String(
      decoding: encoder.encode(profile.mapping),
      as: UTF8.self
    )
    try connection.execute(
      """
      INSERT INTO import_profiles (
          id, name, source_kind, encoding, delimiter, has_header, mapping_json, updated_at
      ) VALUES (?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          source_kind = excluded.source_kind,
          encoding = excluded.encoding,
          delimiter = excluded.delimiter,
          has_header = excluded.has_header,
          mapping_json = excluded.mapping_json,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(profile.id.db), .text(profile.name), .text(profile.sourceKind.rawValue),
        .text(profile.encoding.rawValue), .text(profile.delimiter.rawValue),
        .integer(profile.hasHeader ? 1 : 0), .text(mapping),
        .real(profile.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func profiles() throws -> [ImportProfile] {
    try connection.query("SELECT * FROM import_profiles ORDER BY name").map { row in
      let mappingData = Data(try row.textValue("mapping_json").utf8)
      return ImportProfile(
        id: try row.uuid("id"),
        name: try row.textValue("name"),
        sourceKind: try row.enumeration("source_kind"),
        encoding: try row.enumeration("encoding"),
        delimiter: try row.enumeration("delimiter"),
        hasHeader: try row.boolean("has_header"),
        mapping: try decoder.decode(ImportColumnMapping.self, from: mappingData),
        updatedAt: try row.dateValue("updated_at")
      )
    }
  }

  public func saveBatch(_ batch: ImportBatch) throws {
    try connection.transaction { try persistBatch(batch) }
  }

  func persistBatch(_ batch: ImportBatch) throws {
    try connection.execute(
      """
      INSERT INTO import_batches(id, profile_id, source_filename, imported_at, state)
      VALUES (?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET state = excluded.state
      """,
      bindings: [
        .text(batch.id.db), batch.profileID.map { .text($0.db) } ?? .null,
        .text(batch.sourceFilename), .real(batch.importedAt.timeIntervalSince1970),
        .text(batch.state.rawValue),
      ]
    )
    try connection.execute(
      "DELETE FROM imported_transactions WHERE batch_id = ?",
      bindings: [.text(batch.id.db)]
    )
    try connection.execute(
      "DELETE FROM import_row_errors WHERE batch_id = ?",
      bindings: [.text(batch.id.db)]
    )
    for transaction in batch.transactions {
      try connection.execute(
        """
        INSERT INTO imported_transactions (
            id, batch_id, row_number, transaction_date, amount_yen, description,
            external_id, running_balance_yen, state, evidence_id, journal_entry_id,
            duplicate_of_id
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        bindings: [
          .text(transaction.id.db), .text(transaction.batchID.db),
          .integer(Int64(transaction.rowNumber)),
          .real(transaction.transactionDate.timeIntervalSince1970),
          .integer(transaction.amount.yen), .text(transaction.description),
          transaction.externalID.sqlite,
          transaction.runningBalance.map { .integer($0.yen) } ?? .null,
          .text(transaction.state.rawValue),
          transaction.evidenceID.map { .text($0.db) } ?? .null,
          transaction.journalEntryID.map { .text($0.db) } ?? .null,
          transaction.duplicateOfID.map { .text($0.db) } ?? .null,
        ]
      )
    }
    for error in batch.errors {
      try connection.execute(
        "INSERT INTO import_row_errors(id, batch_id, row_number, raw_row, message) VALUES (?,?,?,?,?)",
        bindings: [
          .text(error.id.db), .text(error.batchID.db), .integer(Int64(error.rowNumber)),
          .text(error.rawRow), .text(error.message),
        ]
      )
    }
  }

  public func batches() throws -> [ImportBatch] {
    try connection.query("SELECT * FROM import_batches ORDER BY imported_at DESC").map { row in
      let id = try row.uuid("id")
      return ImportBatch(
        id: id,
        profileID: try row.optionalUUIDValue("profile_id"),
        sourceFilename: try row.textValue("source_filename"),
        importedAt: try row.dateValue("imported_at"),
        state: try row.enumeration("state"),
        transactions: try transactions(batchID: id),
        errors: try errors(batchID: id)
      )
    }
  }

  public func transactions(states: Set<ImportedTransactionState>) throws -> [ImportedTransaction] {
    guard !states.isEmpty else { return [] }
    let ordered = states.sorted { $0.rawValue < $1.rawValue }
    return try connection.query(
      "SELECT * FROM imported_transactions WHERE state IN (\(Array(repeating: "?", count: ordered.count).joined(separator: ","))) ORDER BY transaction_date DESC, row_number",
      bindings: ordered.map { .text($0.rawValue) }
    ).map(decodeTransaction)
  }

  public func cancelBatch(id: EntityID) throws {
    try connection.transaction {
      let posted =
        try connection.scalarInt(
          "SELECT COUNT(*) FROM imported_transactions WHERE batch_id = ? AND state = 'posted'",
          bindings: [.text(id.db)]
        ) ?? 0
      guard posted == 0 else { throw EvidenceError.confirmationRequired }
      try connection.execute(
        "UPDATE imported_transactions SET state = 'excluded' WHERE batch_id = ?",
        bindings: [.text(id.db)]
      )
      try connection.execute(
        "UPDATE import_batches SET state = 'cancelled' WHERE id = ?",
        bindings: [.text(id.db)]
      )
    }
  }

  public func updateTransaction(_ transaction: ImportedTransaction) throws {
    try connection.execute(
      """
      UPDATE imported_transactions SET
          state = ?, evidence_id = ?, journal_entry_id = ?, duplicate_of_id = ?
      WHERE id = ?
      """,
      bindings: [
        .text(transaction.state.rawValue),
        transaction.evidenceID.map { .text($0.db) } ?? .null,
        transaction.journalEntryID.map { .text($0.db) } ?? .null,
        transaction.duplicateOfID.map { .text($0.db) } ?? .null,
        .text(transaction.id.db),
      ]
    )
  }

  private func transactions(batchID: EntityID) throws -> [ImportedTransaction] {
    try connection.query(
      "SELECT * FROM imported_transactions WHERE batch_id = ? ORDER BY row_number",
      bindings: [.text(batchID.db)]
    ).map(decodeTransaction)
  }

  private func errors(batchID: EntityID) throws -> [ImportRowError] {
    try connection.query(
      "SELECT * FROM import_row_errors WHERE batch_id = ? ORDER BY row_number",
      bindings: [.text(batchID.db)]
    ).map { row in
      ImportRowError(
        id: try row.uuid("id"),
        batchID: try row.uuid("batch_id"),
        rowNumber: Int(try row.integerValue("row_number")),
        rawRow: try row.textValue("raw_row"),
        message: try row.textValue("message")
      )
    }
  }

  private func decodeTransaction(_ row: SQLiteRow) throws -> ImportedTransaction {
    ImportedTransaction(
      id: try row.uuid("id"),
      batchID: try row.uuid("batch_id"),
      rowNumber: Int(try row.integerValue("row_number")),
      transactionDate: try row.dateValue("transaction_date"),
      amount: Money(yen: try row.integerValue("amount_yen")),
      description: try row.textValue("description"),
      externalID: row.optionalText("external_id"),
      runningBalance: row["running_balance_yen"]?.int64.map(Money.init(yen:)),
      state: try row.enumeration("state"),
      evidenceID: try row.optionalUUIDValue("evidence_id"),
      journalEntryID: try row.optionalUUIDValue("journal_entry_id"),
      duplicateOfID: try row.optionalUUIDValue("duplicate_of_id")
    )
  }
}

extension UUID {
  fileprivate var db: String { uuidString.lowercased() }
}

extension Optional where Wrapped == String {
  fileprivate var sqlite: SQLiteValue { map(SQLiteValue.text) ?? .null }
}

extension Optional where Wrapped == Date {
  fileprivate var sqlite: SQLiteValue {
    map { .real($0.timeIntervalSince1970) } ?? .null
  }
}

extension Dictionary where Key == String, Value == SQLiteValue {
  fileprivate func textValue(_ key: String) throws -> String {
    guard case .text(let value)? = self[key] else {
      throw RepositoryError.invalidData("Expected text for \(key)")
    }
    return value
  }

  fileprivate func optionalText(_ key: String) -> String? {
    guard case .text(let value)? = self[key] else { return nil }
    return value
  }

  fileprivate func integerValue(_ key: String) throws -> Int64 {
    guard case .integer(let value)? = self[key] else {
      throw RepositoryError.invalidData("Expected integer for \(key)")
    }
    return value
  }

  fileprivate func number(_ key: String) throws -> Double {
    guard let value = self[key]?.double else {
      throw RepositoryError.invalidData("Expected number for \(key)")
    }
    return value
  }

  fileprivate func boolean(_ key: String) throws -> Bool { try integerValue(key) != 0 }

  fileprivate func dateValue(_ key: String) throws -> Date {
    guard let value = self[key]?.double else {
      throw RepositoryError.invalidData("Expected date for \(key)")
    }
    return Date(timeIntervalSince1970: value)
  }

  fileprivate func optionalDate(_ key: String) -> Date? {
    self[key]?.double.map(Date.init(timeIntervalSince1970:))
  }

  fileprivate func uuid(_ key: String) throws -> UUID {
    let value = try textValue(key)
    guard let result = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return result
  }

  fileprivate func optionalUUIDValue(_ key: String) throws -> UUID? {
    guard let value = optionalText(key) else { return nil }
    guard let result = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return result
  }

  fileprivate func enumeration<T: RawRepresentable>(_ key: String) throws -> T
  where T.RawValue == String {
    let value = try textValue(key)
    guard let result = T(rawValue: value) else {
      throw RepositoryError.invalidData("Invalid value '\(value)' for \(key)")
    }
    return result
  }
}
