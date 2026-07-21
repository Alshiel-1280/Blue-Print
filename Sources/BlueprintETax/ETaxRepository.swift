import BlueprintDomain

public protocol ETaxRepository: Sendable {
  func saveExport(_ record: ETaxExportRecord) throws
  func exports(fiscalYearID: EntityID) throws -> [ETaxExportRecord]
}
