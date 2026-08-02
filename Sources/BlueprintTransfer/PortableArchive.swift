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

public struct Argon2idParameters: Codable, Equatable, Sendable {
  public var version: Int
  public var memoryKiB: Int
  public var iterations: Int
  public var parallelism: Int
  public var outputBytes: Int
  public var saltBase64: String

  public init(
    version: Int = 19,
    memoryKiB: Int,
    iterations: Int,
    parallelism: Int,
    outputBytes: Int,
    saltBase64: String
  ) {
    self.version = version
    self.memoryKiB = memoryKiB
    self.iterations = iterations
    self.parallelism = parallelism
    self.outputBytes = outputBytes
    self.saltBase64 = saltBase64
  }
}

public struct BackupEnvelopeV9: Codable, Equatable, Sendable {
  public var formatName: String
  public var formatVersion: Int
  public var formatFamily: String
  public var encryption: String
  public var keyDerivation: String
  public var kdf: Argon2idParameters
  public var sealedDataBase64: String

  public init(
    formatName: String = "blueprint-encrypted-backup",
    formatVersion: Int = 9,
    formatFamily: String = "blueprint-v1",
    encryption: String = "AES-256-GCM",
    keyDerivation: String = "Argon2id-v19",
    kdf: Argon2idParameters,
    sealedDataBase64: String
  ) {
    self.formatName = formatName
    self.formatVersion = formatVersion
    self.formatFamily = formatFamily
    self.encryption = encryption
    self.keyDerivation = keyDerivation
    self.kdf = kdf
    self.sealedDataBase64 = sealedDataBase64
  }
}

public enum EncryptedBackupKind: Equatable, Sendable {
  case currentV9
  case legacyV8
}

public struct V2BackupFile: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sha256: String
  public let byteCount: Int64
  public let dataBase64: String

  public init(
    relativePath: String,
    sha256: String,
    byteCount: Int64,
    dataBase64: String
  ) {
    self.relativePath = relativePath
    self.sha256 = sha256
    self.byteCount = byteCount
    self.dataBase64 = dataBase64
  }
}

public struct V2BackupPayload: Codable, Equatable, Sendable {
  public let storageGeneration: Int
  public let databaseSchemaVersion: Int
  public let createdAt: Date
  public let databaseSHA256: String
  public let databaseBase64: String
  public let evidenceFiles: [V2BackupFile]

  public init(
    storageGeneration: Int = 2,
    databaseSchemaVersion: Int = 1,
    createdAt: Date,
    databaseSHA256: String,
    databaseBase64: String,
    evidenceFiles: [V2BackupFile]
  ) {
    self.storageGeneration = storageGeneration
    self.databaseSchemaVersion = databaseSchemaVersion
    self.createdAt = createdAt
    self.databaseSHA256 = databaseSHA256
    self.databaseBase64 = databaseBase64
    self.evidenceFiles = evidenceFiles
  }
}

public struct BackupEnvelopeV2: Codable, Equatable, Sendable {
  public let formatName: String
  public let formatFamily: String
  public let formatVersion: Int
  public let storageGeneration: Int
  public let encryption: String
  public let keyDerivation: String
  public let kdf: Argon2idParameters
  public let sealedDataBase64: String

  public init(
    formatName: String = "blueprint-v2-encrypted-backup",
    formatFamily: String = "blueprint-v2",
    formatVersion: Int = 1,
    storageGeneration: Int = 2,
    encryption: String = "AES-256-GCM",
    keyDerivation: String = "Argon2id-v19",
    kdf: Argon2idParameters,
    sealedDataBase64: String
  ) {
    self.formatName = formatName
    self.formatFamily = formatFamily
    self.formatVersion = formatVersion
    self.storageGeneration = storageGeneration
    self.encryption = encryption
    self.keyDerivation = keyDerivation
    self.kdf = kdf
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
  public var code: String?
  public var title: String
  public var detail: String
  public var affectedRecordCount: Int?
  public var repairKind: String?

  public init(
    id: UUID = UUID(),
    severity: Severity,
    code: String? = nil,
    title: String,
    detail: String,
    affectedRecordCount: Int? = nil,
    repairKind: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.code = code
    self.title = title
    self.detail = detail
    self.affectedRecordCount = affectedRecordCount
    self.repairKind = repairKind
  }
}

public enum RepairPlanState: String, Codable, Sendable {
  case previewed
  case applied
}

public struct RepairChange: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: String
  public let summary: String
  public let affectedRecordCount: Int

  public init(
    id: UUID = UUID(),
    kind: String,
    summary: String,
    affectedRecordCount: Int
  ) {
    self.id = id
    self.kind = kind
    self.summary = summary
    self.affectedRecordCount = affectedRecordCount
  }
}

public struct RepairPlan: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let createdAt: Date
  public let findingIDs: [UUID]
  public let backupURL: URL
  public let changes: [RepairChange]
  public var state: RepairPlanState

  public init(
    id: UUID = UUID(),
    createdAt: Date,
    findingIDs: [UUID],
    backupURL: URL,
    changes: [RepairChange],
    state: RepairPlanState = .previewed
  ) {
    self.id = id
    self.createdAt = createdAt
    self.findingIDs = findingIDs
    self.backupURL = backupURL
    self.changes = changes
    self.state = state
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
