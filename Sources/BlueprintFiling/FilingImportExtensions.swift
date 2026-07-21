import BlueprintDomain
import Foundation

public struct FilingImportDocument: Equatable, Sendable {
  public let data: Data
  public let filename: String
  public let mimeType: String

  public init(data: Data, filename: String, mimeType: String) {
    self.data = data
    self.filename = filename
    self.mimeType = mimeType
  }
}

public struct FilingImportIssue: Equatable, Sendable {
  public let field: String
  public let message: String

  public init(field: String, message: String) {
    self.field = field
    self.message = message
  }
}

public struct FilingImportResult<Value: Sendable>: Sendable {
  public let value: Value?
  public let issues: [FilingImportIssue]

  public init(value: Value?, issues: [FilingImportIssue]) {
    self.value = value
    self.issues = issues
  }
}

public protocol WageStatementImporting: Sendable {
  var supportedMimeTypes: Set<String> { get }
  func importStatement(
    _ document: FilingImportDocument, fiscalYearID: EntityID
  ) throws -> FilingImportResult<WageWithholdingStatement>
}

public protocol SecuritiesAnnualReportImporting: Sendable {
  var supportedMimeTypes: Set<String> { get }
  func importReport(
    _ document: FilingImportDocument, fiscalYearID: EntityID
  ) throws -> FilingImportResult<SecuritiesAnnualReport>
}
