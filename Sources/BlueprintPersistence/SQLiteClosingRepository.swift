import BlueprintClosing
import BlueprintDomain
import Foundation

public final class SQLiteClosingRepository: ClosingRepository, @unchecked Sendable {
  private let connection: SQLiteConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveAsset(_ asset: FixedAsset) throws {
    try connection.execute(
      """
      INSERT INTO fixed_assets(
          id, fiscal_year_id, code, name, status, service_date, payload_json, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          code = excluded.code,
          name = excluded.name,
          status = excluded.status,
          service_date = excluded.service_date,
          payload_json = excluded.payload_json,
          updated_at = excluded.updated_at
      """,
      bindings: [
        .text(asset.id.closingDB), .text(asset.fiscalYearID.closingDB), .text(asset.code),
        .text(asset.name), .text(asset.status.rawValue),
        .real(asset.serviceDate.timeIntervalSince1970), .text(try json(asset)),
        .real(asset.metadata.createdAt.timeIntervalSince1970),
        .real(asset.metadata.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  public func asset(id: EntityID) throws -> FixedAsset? {
    try connection.query(
      "SELECT payload_json FROM fixed_assets WHERE id = ?",
      bindings: [.text(id.closingDB)]
    ).first.map { try decode(FixedAsset.self, row: $0) }
  }

  public func assets(fiscalYearID: EntityID) throws -> [FixedAsset] {
    try connection.query(
      "SELECT payload_json FROM fixed_assets WHERE fiscal_year_id = ? ORDER BY code",
      bindings: [.text(fiscalYearID.closingDB)]
    ).map { try decode(FixedAsset.self, row: $0) }
  }

  public func saveHouseholdRule(_ rule: HouseholdAllocationRule) throws {
    try connection.execute(
      """
      INSERT INTO household_allocation_rules(id, name, payload_json) VALUES (?,?,?)
      ON CONFLICT(id) DO UPDATE SET name = excluded.name, payload_json = excluded.payload_json
      """,
      bindings: [.text(rule.id.closingDB), .text(rule.name), .text(try json(rule))]
    )
  }

  public func householdRules() throws -> [HouseholdAllocationRule] {
    try connection.query(
      "SELECT payload_json FROM household_allocation_rules ORDER BY name"
    ).map { try decode(HouseholdAllocationRule.self, row: $0) }
  }

  public func saveAccrualTemplate(_ template: AccrualTemplate) throws {
    try connection.execute(
      """
      INSERT INTO accrual_templates(id, name, kind, payload_json) VALUES (?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          name = excluded.name, kind = excluded.kind, payload_json = excluded.payload_json
      """,
      bindings: [
        .text(template.id.closingDB), .text(template.name), .text(template.kind.rawValue),
        .text(try json(template)),
      ]
    )
  }

  public func accrualTemplates() throws -> [AccrualTemplate] {
    try connection.query(
      "SELECT payload_json FROM accrual_templates ORDER BY name"
    ).map { try decode(AccrualTemplate.self, row: $0) }
  }

  public func saveInventory(_ inventory: InventoryClosing, fiscalYearID: EntityID) throws {
    try connection.execute(
      """
      INSERT INTO closing_inventories(fiscal_year_id, payload_json) VALUES (?,?)
      ON CONFLICT(fiscal_year_id) DO UPDATE SET payload_json = excluded.payload_json
      """,
      bindings: [.text(fiscalYearID.closingDB), .text(try json(inventory))]
    )
  }

  public func inventory(fiscalYearID: EntityID) throws -> InventoryClosing? {
    try connection.query(
      "SELECT payload_json FROM closing_inventories WHERE fiscal_year_id = ?",
      bindings: [.text(fiscalYearID.closingDB)]
    ).first.map { try decode(InventoryClosing.self, row: $0) }
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func decode<T: Decodable>(_ type: T.Type, row: SQLiteRow) throws -> T {
    guard let value = row["payload_json"]?.string else {
      throw RepositoryError.invalidData("closing payload")
    }
    return try decoder.decode(type, from: Data(value.utf8))
  }
}

extension UUID {
  fileprivate var closingDB: String { uuidString.lowercased() }
}
