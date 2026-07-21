import BlueprintDomain
import BlueprintETax
import Foundation

public final class SQLiteETaxRepository: ETaxRepository, @unchecked Sendable {
  private let connection: SQLiteConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(connection: SQLiteConnection) {
    self.connection = connection
  }

  public func saveExport(_ record: ETaxExportRecord) throws {
    try connection.execute(
      """
      INSERT INTO e_tax_exports(id, fiscal_year_id, exported_at, file_hash, payload_json)
      VALUES (?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
          exported_at = excluded.exported_at,
          file_hash = excluded.file_hash,
          payload_json = excluded.payload_json
      """,
      bindings: [
        .text(record.id.uuidString.lowercased()),
        .text(record.fiscalYearID.uuidString.lowercased()),
        .real(record.exportedAt.timeIntervalSince1970),
        .text(record.fileHash),
        .text(String(decoding: try encoder.encode(record), as: UTF8.self)),
      ]
    )
  }

  public func exports(fiscalYearID: EntityID) throws -> [ETaxExportRecord] {
    try connection.query(
      """
      SELECT payload_json FROM e_tax_exports
      WHERE fiscal_year_id = ? ORDER BY exported_at DESC
      """,
      bindings: [.text(fiscalYearID.uuidString.lowercased())]
    ).map { row in
      guard let json = row["payload_json"]?.string else {
        throw RepositoryError.invalidData("e-Tax export payload")
      }
      return try decoder.decode(ETaxExportRecord.self, from: Data(json.utf8))
    }
  }
}
