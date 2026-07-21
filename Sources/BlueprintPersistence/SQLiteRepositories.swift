import BlueprintAudit
import BlueprintDomain
import Foundation

public final class SQLiteBusinessProfileRepository: BusinessProfileRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func save(_ profile: BusinessProfile) throws {
    try connection.execute(
      """
      INSERT INTO business_profiles (
          id, fiscal_year_id, owner_name, trade_name, postal_address, tax_address,
          tax_office, industry, opened_on, blue_return_approved, bookkeeping_style,
          consumption_tax_status, invoice_registration_status, invoice_registration_number,
          invoice_registered_on, invoice_cancelled_on, tax_accounting_method, rounding_rule,
          default_tax_rate, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          owner_name = excluded.owner_name,
          trade_name = excluded.trade_name,
          postal_address = excluded.postal_address,
          tax_address = excluded.tax_address,
          tax_office = excluded.tax_office,
          industry = excluded.industry,
          opened_on = excluded.opened_on,
          blue_return_approved = excluded.blue_return_approved,
          bookkeeping_style = excluded.bookkeeping_style,
          consumption_tax_status = excluded.consumption_tax_status,
          invoice_registration_status = excluded.invoice_registration_status,
          invoice_registration_number = excluded.invoice_registration_number,
          invoice_registered_on = excluded.invoice_registered_on,
          invoice_cancelled_on = excluded.invoice_cancelled_on,
          tax_accounting_method = excluded.tax_accounting_method,
          rounding_rule = excluded.rounding_rule,
          default_tax_rate = excluded.default_tax_rate,
          updated_at = excluded.updated_at
      """,
      bindings: profile.bindings
    )
  }

  public func fetch(id: EntityID) throws -> BusinessProfile? {
    try connection.query(
      "SELECT * FROM business_profiles WHERE id = ?",
      bindings: [.text(id.databaseString)]
    ).first.map(BusinessProfile.init(row:))
  }

  public func fetchAll() throws -> [BusinessProfile] {
    try connection.query("SELECT * FROM business_profiles ORDER BY created_at").map(
      BusinessProfile.init(row:))
  }
}

public final class SQLiteFiscalYearRepository: FiscalYearRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func save(_ fiscalYear: FiscalYear) throws {
    try connection.execute(
      """
      INSERT INTO fiscal_years (
          id, calendar_year, status, tax_rule_set_id, form_rule_set_id,
          locked_at, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          status = excluded.status,
          tax_rule_set_id = excluded.tax_rule_set_id,
          form_rule_set_id = excluded.form_rule_set_id,
          locked_at = excluded.locked_at,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(fiscalYear.id.databaseString),
        .integer(Int64(fiscalYear.calendarYear)),
        .text(fiscalYear.status.rawValue),
        .text(fiscalYear.taxRuleSetID),
        .text(fiscalYear.formRuleSetID),
        fiscalYear.lockedAt.sqliteValue,
        .real(fiscalYear.metadata.createdAt.timeIntervalSince1970),
        .real(fiscalYear.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func fetch(id: EntityID) throws -> FiscalYear? {
    try connection.query(
      "SELECT * FROM fiscal_years WHERE id = ?",
      bindings: [.text(id.databaseString)]
    ).first.map(FiscalYear.init(row:))
  }

  public func fetch(calendarYear: Int) throws -> FiscalYear? {
    try connection.query(
      "SELECT * FROM fiscal_years WHERE calendar_year = ?",
      bindings: [.integer(Int64(calendarYear))]
    ).first.map(FiscalYear.init(row:))
  }

  public func fetchAll() throws -> [FiscalYear] {
    try connection.query("SELECT * FROM fiscal_years ORDER BY calendar_year DESC").map(
      FiscalYear.init(row:))
  }
}

public final class SQLiteAccountRepository: AccountRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func save(_ account: Account) throws {
    try connection.execute(
      """
      INSERT INTO accounts (
          id, code, name, category, normal_balance, default_tax_rate, statement_section,
          display_order, is_active, is_system, created_at, updated_at
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
      bindings: account.bindings
    )
  }

  public func seedStandardAccounts(createdAt: Date) throws {
    for account in StandardChartOfAccounts.accounts(createdAt: createdAt) {
      try connection.execute(
        """
        INSERT OR IGNORE INTO accounts (
            id, code, name, category, normal_balance, default_tax_rate, statement_section,
            display_order, is_active, is_system, created_at, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        bindings: account.bindings
      )
    }
  }

  public func fetchAll(includeInactive: Bool = true) throws -> [Account] {
    let filter = includeInactive ? "" : "WHERE is_active = 1"
    return try connection.query(
      "SELECT * FROM accounts \(filter) ORDER BY display_order, code"
    ).map(Account.init(row:))
  }

  public func deactivate(id: EntityID, at date: Date) throws {
    try connection.execute(
      "UPDATE accounts SET is_active = 0, updated_at = ? WHERE id = ?",
      bindings: [.real(date.timeIntervalSince1970), .text(id.databaseString)]
    )
    guard sqliteChanges(connection) > 0 else { throw RepositoryError.notFound }
  }

  public func delete(id: EntityID) throws {
    throw RepositoryError.physicalDeletionForbidden
  }

  private func sqliteChanges(_ connection: SQLiteConnection) -> Int {
    (try? connection.scalarInt("SELECT changes()")).map(Int.init) ?? 0
  }
}

public final class SQLiteAuditEventRepository: AuditEventRepository, @unchecked Sendable {
  private let connection: SQLiteConnection

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func append(_ event: AuditEvent) throws {
    try connection.execute(
      """
      INSERT INTO audit_events (
          id, occurred_at, actor_kind, action, target_type, target_id, reason, related_event_id
      ) VALUES (?,?,?,?,?,?,?,?)
      """,
      bindings: [
        .text(event.id.databaseString),
        .real(event.occurredAt.timeIntervalSince1970),
        .text(event.actorKind.rawValue),
        .text(event.action.rawValue),
        .text(event.targetType),
        .text(event.targetID),
        event.reason.sqliteValue,
        event.relatedEventID.map { .text($0.databaseString) } ?? .null,
      ]
    )
  }

  public func fetchAll() throws -> [AuditEvent] {
    try connection.query("SELECT * FROM audit_events ORDER BY occurred_at, id").map(
      AuditEvent.init(row:))
  }

  public func fetch(targetType: String, targetID: String) throws -> [AuditEvent] {
    try connection.query(
      """
      SELECT * FROM audit_events
      WHERE target_type = ? AND target_id = ?
      ORDER BY occurred_at, id
      """,
      bindings: [.text(targetType), .text(targetID)]
    ).map(AuditEvent.init(row:))
  }
}

extension UUID {
  fileprivate var databaseString: String { uuidString.lowercased() }
}

extension Optional where Wrapped == Date {
  fileprivate var sqliteValue: SQLiteValue {
    map { .real($0.timeIntervalSince1970) } ?? .null
  }
}

extension Optional where Wrapped == String {
  fileprivate var sqliteValue: SQLiteValue {
    map(SQLiteValue.text) ?? .null
  }
}

extension BusinessProfile {
  fileprivate var bindings: [SQLiteValue] {
    [
      .text(id.databaseString),
      .text(fiscalYearID.databaseString),
      .text(ownerName),
      .text(tradeName),
      .text(postalAddress),
      .text(taxAddress),
      .text(taxOffice),
      .text(industry),
      openedOn.sqliteValue,
      .integer(blueReturnApproved ? 1 : 0),
      .text(bookkeepingStyle.rawValue),
      .text(consumptionTaxStatus.rawValue),
      .text(invoiceRegistrationStatus.rawValue),
      invoiceRegistrationNumber.sqliteValue,
      invoiceRegisteredOn.sqliteValue,
      invoiceCancelledOn.sqliteValue,
      .text(taxAccountingMethod.rawValue),
      .text(roundingRule.rawValue),
      .text(defaultTaxRate.rawValue),
      .real(metadata.createdAt.timeIntervalSince1970),
      .real(metadata.updatedAt.timeIntervalSince1970),
    ]
  }

  fileprivate init(row: SQLiteRow) throws {
    self.init(
      metadata: try row.metadata(),
      fiscalYearID: try row.uuid("fiscal_year_id"),
      ownerName: try row.text("owner_name"),
      tradeName: try row.text("trade_name"),
      postalAddress: try row.text("postal_address"),
      taxAddress: try row.text("tax_address"),
      taxOffice: try row.text("tax_office"),
      industry: try row.text("industry"),
      openedOn: row.dateIfPresent("opened_on"),
      blueReturnApproved: try row.bool("blue_return_approved"),
      bookkeepingStyle: try row.enumValue("bookkeeping_style"),
      consumptionTaxStatus: try row.enumValue("consumption_tax_status"),
      invoiceRegistrationStatus: try row.enumValue("invoice_registration_status"),
      invoiceRegistrationNumber: row.textIfPresent("invoice_registration_number"),
      invoiceRegisteredOn: row.dateIfPresent("invoice_registered_on"),
      invoiceCancelledOn: row.dateIfPresent("invoice_cancelled_on"),
      taxAccountingMethod: try row.enumValue("tax_accounting_method"),
      roundingRule: try row.enumValue("rounding_rule"),
      defaultTaxRate: try row.enumValue("default_tax_rate")
    )
  }
}

extension FiscalYear {
  fileprivate init(row: SQLiteRow) throws {
    try self.init(
      metadata: try row.metadata(),
      calendarYear: Int(try row.integer("calendar_year")),
      status: try row.enumValue("status"),
      taxRuleSetID: try row.text("tax_rule_set_id"),
      formRuleSetID: try row.text("form_rule_set_id"),
      lockedAt: row.dateIfPresent("locked_at")
    )
  }
}

extension Account {
  fileprivate var bindings: [SQLiteValue] {
    [
      .text(id.databaseString),
      .text(code),
      .text(name),
      .text(category.rawValue),
      .text(normalBalance.rawValue),
      .text(defaultTaxRate.rawValue),
      .text(statementSection.rawValue),
      .integer(Int64(displayOrder)),
      .integer(isActive ? 1 : 0),
      .integer(isSystem ? 1 : 0),
      .real(metadata.createdAt.timeIntervalSince1970),
      .real(metadata.updatedAt.timeIntervalSince1970),
    ]
  }

  fileprivate init(row: SQLiteRow) throws {
    self.init(
      metadata: try row.metadata(),
      code: try row.text("code"),
      name: try row.text("name"),
      category: try row.enumValue("category"),
      normalBalance: try row.enumValue("normal_balance"),
      defaultTaxRate: try row.enumValue("default_tax_rate"),
      statementSection: try row.enumValue("statement_section"),
      displayOrder: Int(try row.integer("display_order")),
      isActive: try row.bool("is_active"),
      isSystem: try row.bool("is_system")
    )
  }
}

extension AuditEvent {
  fileprivate init(row: SQLiteRow) throws {
    self.init(
      id: try row.uuid("id"),
      occurredAt: try row.date("occurred_at"),
      actorKind: try row.enumValue("actor_kind"),
      action: try row.enumValue("action"),
      targetType: try row.text("target_type"),
      targetID: try row.text("target_id"),
      reason: row.textIfPresent("reason"),
      relatedEventID: try row.optionalUUID("related_event_id")
    )
  }
}

extension Dictionary where Key == String, Value == SQLiteValue {
  fileprivate func metadata() throws -> EntityMetadata {
    EntityMetadata(
      id: try uuid("id"),
      createdAt: try date("created_at"),
      updatedAt: try date("updated_at")
    )
  }

  fileprivate func text(_ key: String) throws -> String {
    guard case .text(let value)? = self[key] else {
      throw RepositoryError.invalidData("Expected text for \(key)")
    }
    return value
  }

  fileprivate func textIfPresent(_ key: String) -> String? {
    guard case .text(let value)? = self[key] else { return nil }
    return value
  }

  fileprivate func integer(_ key: String) throws -> Int64 {
    guard case .integer(let value)? = self[key] else {
      throw RepositoryError.invalidData("Expected integer for \(key)")
    }
    return value
  }

  fileprivate func bool(_ key: String) throws -> Bool {
    try integer(key) != 0
  }

  fileprivate func date(_ key: String) throws -> Date {
    guard let seconds = self[key]?.double else {
      throw RepositoryError.invalidData("Expected date for \(key)")
    }
    return Date(timeIntervalSince1970: seconds)
  }

  fileprivate func dateIfPresent(_ key: String) -> Date? {
    self[key]?.double.map(Date.init(timeIntervalSince1970:))
  }

  fileprivate func uuid(_ key: String) throws -> UUID {
    let value = try text(key)
    guard let id = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return id
  }

  fileprivate func optionalUUID(_ key: String) throws -> UUID? {
    guard let value = textIfPresent(key) else { return nil }
    guard let id = UUID(uuidString: value) else {
      throw RepositoryError.invalidData("Invalid UUID for \(key)")
    }
    return id
  }

  fileprivate func enumValue<T: RawRepresentable>(_ key: String) throws -> T
  where T.RawValue == String {
    let value = try text(key)
    guard let result = T(rawValue: value) else {
      throw RepositoryError.invalidData("Invalid value '\(value)' for \(key)")
    }
    return result
  }
}
