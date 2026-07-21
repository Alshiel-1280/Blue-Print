import Foundation

public enum PortableValue: Codable, Equatable, Sendable {
  case integer(Int64)
  case real(Double)
  case text(String)
  case blobBase64(String)
  case null

  private enum CodingKeys: String, CodingKey { case type, value }
  private enum Kind: String, Codable { case integer, real, text, blobBase64, null }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
    case .real: self = .real(try container.decode(Double.self, forKey: .value))
    case .text: self = .text(try container.decode(String.self, forKey: .value))
    case .blobBase64: self = .blobBase64(try container.decode(String.self, forKey: .value))
    case .null: self = .null
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .integer(let value):
      try container.encode(Kind.integer, forKey: .type)
      try container.encode(value, forKey: .value)
    case .real(let value):
      try container.encode(Kind.real, forKey: .type)
      try container.encode(value, forKey: .value)
    case .text(let value):
      try container.encode(Kind.text, forKey: .type)
      try container.encode(value, forKey: .value)
    case .blobBase64(let value):
      try container.encode(Kind.blobBase64, forKey: .type)
      try container.encode(value, forKey: .value)
    case .null:
      try container.encode(Kind.null, forKey: .type)
    }
  }
}

public struct PortableTable: Codable, Equatable, Sendable {
  public var name: String
  public var columns: [String]
  public var rows: [[String: PortableValue]]

  public init(name: String, columns: [String], rows: [[String: PortableValue]]) {
    self.name = name
    self.columns = columns
    self.rows = rows
  }
}

public struct PortableEvidence: Codable, Equatable, Sendable {
  public var relativePath: String
  public var sha256: String
  public var byteCount: Int64
  public var dataBase64: String

  public init(relativePath: String, sha256: String, byteCount: Int64, dataBase64: String) {
    self.relativePath = relativePath
    self.sha256 = sha256
    self.byteCount = byteCount
    self.dataBase64 = dataBase64
  }
}

public struct TransferManifest: Codable, Equatable, Sendable {
  public var formatName: String
  public var formatVersion: Int
  public var appVersion: String
  public var databaseSchemaVersion: Int
  public var createdAt: Date
  public var tableRowCounts: [String: Int]
  public var evidenceCount: Int
  public var evidenceHashes: [String]
  public var debitTotalYen: Int64
  public var creditTotalYen: Int64

  public init(
    formatName: String = "blueprint-portable-archive",
    formatVersion: Int,
    appVersion: String,
    databaseSchemaVersion: Int,
    createdAt: Date,
    tableRowCounts: [String: Int],
    evidenceCount: Int,
    evidenceHashes: [String],
    debitTotalYen: Int64,
    creditTotalYen: Int64
  ) {
    self.formatName = formatName
    self.formatVersion = formatVersion
    self.appVersion = appVersion
    self.databaseSchemaVersion = databaseSchemaVersion
    self.createdAt = createdAt
    self.tableRowCounts = tableRowCounts
    self.evidenceCount = evidenceCount
    self.evidenceHashes = evidenceHashes
    self.debitTotalYen = debitTotalYen
    self.creditTotalYen = creditTotalYen
  }
}

public struct PortableArchive: Codable, Equatable, Sendable {
  public var manifest: TransferManifest
  public var tables: [PortableTable]
  public var csvTables: [String: String]
  public var evidence: [PortableEvidence]
  public var databaseSnapshotBase64: String

  public init(
    manifest: TransferManifest,
    tables: [PortableTable],
    csvTables: [String: String],
    evidence: [PortableEvidence],
    databaseSnapshotBase64: String
  ) {
    self.manifest = manifest
    self.tables = tables
    self.csvTables = csvTables
    self.evidence = evidence
    self.databaseSnapshotBase64 = databaseSnapshotBase64
  }
}

public struct EncryptedBackupEnvelope: Codable, Equatable, Sendable {
  public var formatName: String
  public var formatVersion: Int
  public var encryption: String
  public var keyDerivation: String
  public var iterations: Int
  public var saltBase64: String
  public var sealedDataBase64: String

  public init(
    formatName: String = "blueprint-encrypted-backup",
    formatVersion: Int,
    encryption: String = "AES-256-GCM",
    keyDerivation: String = "iterated-SHA256-v1",
    iterations: Int,
    saltBase64: String,
    sealedDataBase64: String
  ) {
    self.formatName = formatName
    self.formatVersion = formatVersion
    self.encryption = encryption
    self.keyDerivation = keyDerivation
    self.iterations = iterations
    self.saltBase64 = saltBase64
    self.sealedDataBase64 = sealedDataBase64
  }
}

public struct RestorePreview: Codable, Equatable, Sendable {
  public var manifest: TransferManifest
  public var isCompatible: Bool
  public var warnings: [String]

  public init(manifest: TransferManifest, isCompatible: Bool, warnings: [String]) {
    self.manifest = manifest
    self.isCompatible = isCompatible
    self.warnings = warnings
  }
}

public struct DiagnosticFinding: Codable, Equatable, Identifiable, Sendable {
  public enum Severity: String, Codable, Sendable { case information, warning, error }

  public let id: UUID
  public var severity: Severity
  public var title: String
  public var detail: String

  public init(
    id: UUID = UUID(),
    severity: Severity,
    title: String,
    detail: String
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.detail = detail
  }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
  public var createdAt: Date
  public var findings: [DiagnosticFinding]
  public var tableRowCounts: [String: Int]
  public var evidenceChecked: Int

  public init(
    createdAt: Date,
    findings: [DiagnosticFinding],
    tableRowCounts: [String: Int],
    evidenceChecked: Int
  ) {
    self.createdAt = createdAt
    self.findings = findings
    self.tableRowCounts = tableRowCounts
    self.evidenceChecked = evidenceChecked
  }

  public var isHealthy: Bool { !findings.contains { $0.severity == .error } }
}
