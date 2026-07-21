import BlueprintDomain
import Foundation

public protocol MigrationBackupHook: Sendable {
  func prepareForMigration(databaseURL: URL, fromVersion: Int, toVersion: Int) throws
}

public struct NoopMigrationBackupHook: MigrationBackupHook {
  public init() {}
  public func prepareForMigration(databaseURL: URL, fromVersion: Int, toVersion: Int) throws {}
}

public struct FileMigrationBackupHook: MigrationBackupHook {
  public let backupDirectory: URL

  public init(backupDirectory: URL) {
    self.backupDirectory = backupDirectory
  }

  public func prepareForMigration(databaseURL: URL, fromVersion: Int, toVersion: Int) throws {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let destination = backupDirectory.appendingPathComponent(
      "blueprint.pre-migration-v\(fromVersion)-to-v\(toVersion).\(timestamp).sqlite"
    )
    try FileManager.default.copyItem(at: databaseURL, to: destination)
  }
}

public struct DatabaseMigrator: Sendable {
  public static let latestVersion = BlueprintVersions.databaseSchema

  public init() {}

  public func migrate(
    connection: SQLiteConnection,
    backupHook: any MigrationBackupHook
  ) throws {
    let currentVersion = Int(try connection.scalarInt("PRAGMA user_version") ?? 0)
    guard currentVersion <= Self.latestVersion else {
      throw SQLiteFailure(
        code: 1,
        message: "DB schema \(currentVersion) is newer than supported schema \(Self.latestVersion)"
      )
    }
    guard currentVersion < Self.latestVersion else { return }

    if currentVersion > 0 {
      try connection.checkpoint()
      try backupHook.prepareForMigration(
        databaseURL: connection.databaseURL,
        fromVersion: currentVersion,
        toVersion: Self.latestVersion
      )
    }

    try connection.transaction {
      for version in (currentVersion + 1)...Self.latestVersion {
        try apply(version: version, connection: connection)
        try connection.execute("PRAGMA user_version = \(version)")
      }
    }
  }

  private func apply(version: Int, connection: SQLiteConnection) throws {
    switch version {
    case 1:
      try applyVersion1(connection)
    case 2:
      try applyVersion2(connection)
    case 3:
      try applyVersion3(connection)
    case 4:
      try applyVersion4(connection)
    default:
      preconditionFailure("Missing migration \(version)")
    }
  }

  private func applyVersion1(_ connection: SQLiteConnection) throws {
    try connection.execute(
      """
      CREATE TABLE version_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE fiscal_years (
          id TEXT PRIMARY KEY NOT NULL,
          calendar_year INTEGER NOT NULL UNIQUE,
          status TEXT NOT NULL CHECK (status IN ('open','closing','filed','locked')),
          tax_rule_set_id TEXT NOT NULL,
          form_rule_set_id TEXT NOT NULL,
          locked_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE business_profiles (
          id TEXT PRIMARY KEY NOT NULL,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          owner_name TEXT NOT NULL,
          trade_name TEXT NOT NULL,
          postal_address TEXT NOT NULL DEFAULT '',
          tax_address TEXT NOT NULL DEFAULT '',
          tax_office TEXT NOT NULL DEFAULT '',
          industry TEXT NOT NULL DEFAULT '',
          opened_on REAL,
          blue_return_approved INTEGER NOT NULL CHECK (blue_return_approved IN (0,1)),
          bookkeeping_style TEXT NOT NULL,
          consumption_tax_status TEXT NOT NULL,
          invoice_registration_status TEXT NOT NULL,
          invoice_registration_number TEXT,
          invoice_registered_on REAL,
          invoice_cancelled_on REAL,
          tax_accounting_method TEXT NOT NULL,
          rounding_rule TEXT NOT NULL,
          default_tax_rate TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(fiscal_year_id)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE accounts (
          id TEXT PRIMARY KEY NOT NULL,
          code TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          category TEXT NOT NULL,
          normal_balance TEXT NOT NULL,
          default_tax_rate TEXT NOT NULL,
          statement_section TEXT NOT NULL,
          display_order INTEGER NOT NULL,
          is_active INTEGER NOT NULL CHECK (is_active IN (0,1)),
          is_system INTEGER NOT NULL CHECK (is_system IN (0,1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE sub_accounts (
          id TEXT PRIMARY KEY NOT NULL,
          account_id TEXT NOT NULL REFERENCES accounts(id),
          code TEXT NOT NULL,
          name TEXT NOT NULL,
          display_order INTEGER NOT NULL,
          is_active INTEGER NOT NULL CHECK (is_active IN (0,1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(account_id, code)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE audit_events (
          id TEXT PRIMARY KEY NOT NULL,
          occurred_at REAL NOT NULL,
          actor_kind TEXT NOT NULL,
          action TEXT NOT NULL,
          target_type TEXT NOT NULL,
          target_id TEXT NOT NULL,
          reason TEXT,
          related_event_id TEXT REFERENCES audit_events(id)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE INDEX audit_events_target_index
      ON audit_events(target_type, target_id, occurred_at)
      """)
    try connection.execute(
      """
      CREATE TRIGGER audit_events_no_update
      BEFORE UPDATE ON audit_events
      BEGIN
          SELECT RAISE(ABORT, 'audit events are append-only');
      END
      """)
    try connection.execute(
      """
      CREATE TRIGGER audit_events_no_delete
      BEFORE DELETE ON audit_events
      BEGIN
          SELECT RAISE(ABORT, 'audit events are append-only');
      END
      """)
    try connection.execute(
      "INSERT INTO version_metadata(key, value) VALUES (?, ?), (?, ?), (?, ?), (?, ?)",
      bindings: [
        .text("app_version"), .text(BlueprintVersions.app),
        .text("data_format_version"), .text(String(BlueprintVersions.dataFormat)),
        .text("tax_rule_set_version"), .text(BlueprintVersions.taxRuleSet),
        .text("form_rule_set_version"), .text(BlueprintVersions.formRuleSet),
      ]
    )
  }

  private func applyVersion2(_ connection: SQLiteConnection) throws {
    try connection.execute(
      """
      CREATE TABLE capture_sources (
          id TEXT PRIMARY KEY NOT NULL,
          document_id TEXT NOT NULL,
          original_sha256 TEXT NOT NULL,
          device_id TEXT NOT NULL,
          device_kind TEXT NOT NULL,
          captured_at REAL NOT NULL,
          mime_type TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
          transfer_state TEXT NOT NULL,
          protocol_version INTEGER NOT NULL,
          canonical_authority TEXT NOT NULL CHECK (canonical_authority = 'mac'),
          UNIQUE(document_id, original_sha256)
      ) STRICT
      """)
    try connection.execute(
      "INSERT OR REPLACE INTO version_metadata(key, value) VALUES (?, ?)",
      bindings: [
        .text("capture_protocol_version"), .text(String(BlueprintVersions.captureProtocol)),
      ]
    )
  }

  private func applyVersion3(_ connection: SQLiteConnection) throws {
    try connection.execute(
      """
      CREATE TABLE journal_entries (
          id TEXT PRIMARY KEY NOT NULL,
          fiscal_year_id TEXT NOT NULL REFERENCES fiscal_years(id),
          transaction_date REAL NOT NULL,
          description TEXT NOT NULL,
          kind TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('draft','pendingReview','posted','reversed','corrected')),
          source_entry_id TEXT REFERENCES journal_entries(id),
          reason TEXT,
          posted_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE journal_lines (
          id TEXT PRIMARY KEY NOT NULL,
          entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
          account_id TEXT NOT NULL REFERENCES accounts(id),
          sub_account_id TEXT REFERENCES sub_accounts(id),
          side TEXT NOT NULL CHECK (side IN ('debit','credit')),
          amount_yen INTEGER NOT NULL CHECK (amount_yen > 0),
          tax_rate TEXT NOT NULL,
          counterparty TEXT NOT NULL DEFAULT '',
          memo TEXT NOT NULL DEFAULT '',
          line_order INTEGER NOT NULL,
          UNIQUE(entry_id, line_order)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE INDEX journal_entries_fiscal_date_index
      ON journal_entries(fiscal_year_id, transaction_date, created_at)
      """)
    try connection.execute(
      """
      CREATE INDEX journal_lines_account_index
      ON journal_lines(account_id, entry_id)
      """)
    try connection.execute(
      """
      CREATE TRIGGER posted_journal_no_delete
      BEFORE DELETE ON journal_entries
      WHEN OLD.status IN ('posted','reversed','corrected')
      BEGIN
          SELECT RAISE(ABORT, 'posted journal entries cannot be deleted');
      END
      """)
    try connection.execute(
      """
      CREATE TRIGGER posted_journal_lines_no_update
      BEFORE UPDATE ON journal_lines
      WHEN (SELECT status FROM journal_entries WHERE id = OLD.entry_id) IN ('posted','reversed','corrected')
      BEGIN
          SELECT RAISE(ABORT, 'posted journal lines cannot be updated');
      END
      """)
    try connection.execute(
      """
      CREATE TRIGGER posted_journal_lines_no_delete
      BEFORE DELETE ON journal_lines
      WHEN (SELECT status FROM journal_entries WHERE id = OLD.entry_id) IN ('posted','reversed','corrected')
      BEGIN
          SELECT RAISE(ABORT, 'posted journal lines cannot be deleted');
      END
      """)
    try connection.execute(
      "INSERT OR REPLACE INTO version_metadata(key, value) VALUES (?, ?), (?, ?)",
      bindings: [
        .text("app_version"), .text(BlueprintVersions.app),
        .text("data_format_version"), .text(String(BlueprintVersions.dataFormat)),
      ]
    )
  }

  private func applyVersion4(_ connection: SQLiteConnection) throws {
    try connection.execute(
      "ALTER TABLE journal_lines ADD COLUMN invoice_status TEXT NOT NULL DEFAULT 'unknown'"
    )
    try connection.execute(
      "ALTER TABLE journal_lines ADD COLUMN deductible_basis_points INTEGER NOT NULL DEFAULT 10000 CHECK (deductible_basis_points BETWEEN 0 AND 10000)"
    )
    try connection.execute(
      "ALTER TABLE journal_lines ADD COLUMN rounding_unit TEXT NOT NULL DEFAULT 'line'"
    )
    try connection.execute(
      """
      CREATE TABLE evidence_documents (
          id TEXT PRIMARY KEY NOT NULL,
          original_sha256 TEXT NOT NULL UNIQUE,
          original_relative_path TEXT NOT NULL UNIQUE,
          original_filename TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK (byte_count > 0),
          acquired_at REAL NOT NULL,
          origin TEXT NOT NULL CHECK (origin IN ('paperScan','electronicTransaction','cameraCapture')),
          state TEXT NOT NULL CHECK (state IN ('unprocessed','needsReview','posted','excluded')),
          transaction_date REAL,
          amount_yen INTEGER,
          counterparty TEXT,
          electronic_transaction INTEGER NOT NULL CHECK (electronic_transaction IN (0,1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE ocr_candidates (
          id TEXT PRIMARY KEY NOT NULL,
          evidence_id TEXT NOT NULL REFERENCES evidence_documents(id),
          field TEXT NOT NULL,
          raw_value TEXT NOT NULL,
          confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
          corrected_value TEXT,
          corrected_at REAL,
          UNIQUE(evidence_id, field, raw_value)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE evidence_links (
          id TEXT PRIMARY KEY NOT NULL,
          evidence_id TEXT NOT NULL REFERENCES evidence_documents(id),
          journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id),
          linked_at REAL NOT NULL,
          UNIQUE(evidence_id, journal_entry_id)
      ) STRICT
      """)
    try connection.execute(
      "CREATE INDEX evidence_search_index ON evidence_documents(transaction_date, amount_yen, counterparty)"
    )
    try connection.execute(
      """
      CREATE TRIGGER evidence_original_identity_no_update
      BEFORE UPDATE OF original_sha256, original_relative_path, original_filename, mime_type,
                       byte_count, acquired_at, origin ON evidence_documents
      BEGIN
          SELECT RAISE(ABORT, 'evidence original identity is immutable');
      END
      """)
    try connection.execute(
      """
      CREATE TABLE import_profiles (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL UNIQUE,
          source_kind TEXT NOT NULL,
          encoding TEXT NOT NULL,
          delimiter TEXT NOT NULL,
          has_header INTEGER NOT NULL CHECK (has_header IN (0,1)),
          mapping_json TEXT NOT NULL,
          updated_at REAL NOT NULL
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE import_batches (
          id TEXT PRIMARY KEY NOT NULL,
          profile_id TEXT REFERENCES import_profiles(id),
          source_filename TEXT NOT NULL,
          imported_at REAL NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('preview','imported','partiallyFailed','cancelled'))
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE imported_transactions (
          id TEXT PRIMARY KEY NOT NULL,
          batch_id TEXT NOT NULL REFERENCES import_batches(id),
          row_number INTEGER NOT NULL,
          transaction_date REAL NOT NULL,
          amount_yen INTEGER NOT NULL,
          description TEXT NOT NULL,
          external_id TEXT,
          running_balance_yen INTEGER,
          state TEXT NOT NULL CHECK (state IN ('unprocessed','needsReview','posted','excluded')),
          evidence_id TEXT REFERENCES evidence_documents(id),
          journal_entry_id TEXT REFERENCES journal_entries(id),
          duplicate_of_id TEXT REFERENCES imported_transactions(id),
          UNIQUE(batch_id, row_number)
      ) STRICT
      """)
    try connection.execute(
      """
      CREATE TABLE import_row_errors (
          id TEXT PRIMARY KEY NOT NULL,
          batch_id TEXT NOT NULL REFERENCES import_batches(id),
          row_number INTEGER NOT NULL,
          raw_row TEXT NOT NULL,
          message TEXT NOT NULL
      ) STRICT
      """)
    try connection.execute(
      "CREATE INDEX imported_transactions_match_index ON imported_transactions(transaction_date, amount_yen, description, external_id)"
    )
    try connection.execute(
      "INSERT OR REPLACE INTO version_metadata(key, value) VALUES (?, ?), (?, ?)",
      bindings: [
        .text("app_version"), .text(BlueprintVersions.app),
        .text("data_format_version"), .text(String(BlueprintVersions.dataFormat)),
      ]
    )
  }
}
