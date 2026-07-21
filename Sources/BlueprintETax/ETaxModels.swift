import BlueprintDomain
import BlueprintTax
import Foundation

public enum ETaxChecklistState: String, Codable, CaseIterable, Sendable {
  case included
  case unsupported
  case additionalInput
}

public struct ETaxChecklistItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let state: ETaxChecklistState

  public init(id: String, title: String, detail: String, state: ETaxChecklistState) {
    self.id = id
    self.title = title
    self.detail = detail
    self.state = state
  }
}

public struct ETaxFieldValue: Codable, Equatable, Identifiable, Sendable {
  public let tag: String
  public let value: String
  public let path: [String]
  public let attributes: [String: String]

  public var id: String { tag }

  public init(
    tag: String,
    value: String,
    path: [String] = [],
    attributes: [String: String] = [:]
  ) {
    self.tag = tag
    self.value = value
    self.path = path
    self.attributes = attributes
  }
}

public struct ETaxIdentity: Codable, Equatable, Sendable {
  public let taxOfficeCode: String
  public let taxOfficeName: String
  public let userID: String
  public let taxpayerName: String
  public let taxpayerAddress: String

  public init(
    taxOfficeCode: String,
    taxOfficeName: String,
    userID: String,
    taxpayerName: String,
    taxpayerAddress: String
  ) {
    self.taxOfficeCode = taxOfficeCode
    self.taxOfficeName = taxOfficeName
    self.userID = userID
    self.taxpayerName = taxpayerName
    self.taxpayerAddress = taxpayerAddress
  }
}

public struct ETaxFormData: Codable, Equatable, Identifiable, Sendable {
  public let formID: String
  public let version: String
  public let page: Int
  public let fields: [ETaxFieldValue]

  public var id: String { "\(formID)-\(page)" }

  public init(formID: String, version: String, page: Int = 1, fields: [ETaxFieldValue]) {
    self.formID = formID
    self.version = version
    self.page = page
    self.fields = fields
  }
}

public struct ETaxReturnData: Codable, Equatable, Sendable {
  public let fiscalYear: Int
  public let procedureID: String
  public let procedureVersion: String
  public let taxRuleSetID: String
  public let formRuleSetID: String
  public let identity: ETaxIdentity
  public let forms: [ETaxFormData]
  public let checklist: [ETaxChecklistItem]
  public let ledgerFingerprint: String

  public init(
    fiscalYear: Int,
    procedureID: String,
    procedureVersion: String,
    taxRuleSetID: String,
    formRuleSetID: String,
    identity: ETaxIdentity,
    forms: [ETaxFormData],
    checklist: [ETaxChecklistItem],
    ledgerFingerprint: String
  ) {
    self.fiscalYear = fiscalYear
    self.procedureID = procedureID
    self.procedureVersion = procedureVersion
    self.taxRuleSetID = taxRuleSetID
    self.formRuleSetID = formRuleSetID
    self.identity = identity
    self.forms = forms
    self.checklist = checklist
    self.ledgerFingerprint = ledgerFingerprint
  }
}

public enum ETaxValidationSeverity: String, Codable, Sendable {
  case error
  case warning
}

public struct ETaxValidationIssue: Codable, Equatable, Identifiable, Sendable {
  public let fieldTag: String?
  public let message: String
  public let severity: ETaxValidationSeverity

  public var id: String { "\(fieldTag ?? "form")|\(message)" }

  public init(fieldTag: String?, message: String, severity: ETaxValidationSeverity) {
    self.fieldTag = fieldTag
    self.message = message
    self.severity = severity
  }
}

public struct ETaxExportRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public let exportedAt: Date
  public let fileName: String
  public let fileHash: String
  public let appVersion: String
  public let taxRuleSetID: String
  public let formRuleSetID: String
  public let schemaVersion: String
  public let ledgerFingerprint: String
  public let checklist: [ETaxChecklistItem]

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    exportedAt: Date,
    fileName: String,
    fileHash: String,
    appVersion: String = BlueprintVersions.app,
    taxRuleSetID: String,
    formRuleSetID: String,
    schemaVersion: String,
    ledgerFingerprint: String,
    checklist: [ETaxChecklistItem]
  ) {
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.exportedAt = exportedAt
    self.fileName = fileName
    self.fileHash = fileHash
    self.appVersion = appVersion
    self.taxRuleSetID = taxRuleSetID
    self.formRuleSetID = formRuleSetID
    self.schemaVersion = schemaVersion
    self.ledgerFingerprint = ledgerFingerprint
    self.checklist = checklist
  }

  public func needsRegeneration(currentLedgerFingerprint: String) -> Bool {
    ledgerFingerprint != currentLedgerFingerprint
  }
}

public struct ETaxGeneratedPackage: Equatable, Sendable {
  public let fileName: String
  public let data: Data
  public let hash: String
}
