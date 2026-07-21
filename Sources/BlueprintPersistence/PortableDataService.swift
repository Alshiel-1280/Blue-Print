import BlueprintDomain
import BlueprintTransfer
import CryptoKit
import Foundation

public enum PortableDataError: Error, Equatable, Sendable {
  case invalidArchive
  case incompatibleVersion(found: Int, supported: Int)
  case authenticationFailed
  case evidenceHashMismatch(path: String)
  case databaseIntegrityFailure(String)
  case destinationNotEmpty
}

public struct PortableDataService: @unchecked Sendable {
  public static let backupIterations = 100_000

  public let connection: SQLiteConnection
  public let root: URL
  private let fileManager: FileManager

  public init(connection: SQLiteConnection, root: URL, fileManager: FileManager = .default) {
    self.connection = connection
    self.root = root
    self.fileManager = fileManager
  }

  public func makeArchive(createdAt: Date = Date()) throws -> PortableArchive {
    try connection.checkpoint()
    let tableNames = try connection.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0["name"]?.string }
    let tables = try tableNames.map(makeTable)
    let evidence = try makeEvidenceArchive()
    let debit =
      try connection.scalarInt(
        "SELECT COALESCE(SUM(amount_yen), 0) FROM journal_lines WHERE side = 'debit'") ?? 0
    let credit =
      try connection.scalarInt(
        "SELECT COALESCE(SUM(amount_yen), 0) FROM journal_lines WHERE side = 'credit'") ?? 0
    let snapshot = try Data(contentsOf: connection.databaseURL)
    let manifest = TransferManifest(
      formatVersion: BlueprintVersions.dataFormat,
      appVersion: BlueprintVersions.app,
      databaseSchemaVersion: BlueprintVersions.databaseSchema,
      createdAt: createdAt,
      tableRowCounts: Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows.count) }),
      evidenceCount: evidence.count,
      evidenceHashes: evidence.map(\.sha256).sorted(),
      debitTotalYen: debit,
      creditTotalYen: credit
    )
    return PortableArchive(
      manifest: manifest,
      tables: tables,
      csvTables: Dictionary(uniqueKeysWithValues: tables.map { ($0.name, makeCSV($0)) }),
      evidence: evidence,
      databaseSnapshotBase64: snapshot.base64EncodedString()
    )
  }

  public func encodeArchive(_ archive: PortableArchive) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(archive)
  }

  public func decodeArchive(_ data: Data) throws -> PortableArchive {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let archive = try? decoder.decode(PortableArchive.self, from: data) else {
      throw PortableDataError.invalidArchive
    }
    try validateCompatibility(archive.manifest)
    return archive
  }

  public func makeEncryptedBackup(
    passphrase: String,
    createdAt: Date = Date()
  ) throws -> Data {
    let archiveData = try encodeArchive(makeArchive(createdAt: createdAt))
    let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    let key = deriveKey(passphrase: passphrase, salt: salt, iterations: Self.backupIterations)
    let sealed = try AES.GCM.seal(archiveData, using: key)
    guard let combined = sealed.combined else { throw PortableDataError.invalidArchive }
    let envelope = EncryptedBackupEnvelope(
      formatVersion: BlueprintVersions.dataFormat,
      iterations: Self.backupIterations,
      saltBase64: salt.base64EncodedString(),
      sealedDataBase64: combined.base64EncodedString()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(envelope)
  }

  public func openEncryptedBackup(_ data: Data, passphrase: String) throws -> PortableArchive {
    guard
      let envelope = try? JSONDecoder().decode(EncryptedBackupEnvelope.self, from: data),
      envelope.formatName == "blueprint-encrypted-backup",
      envelope.encryption == "AES-256-GCM",
      envelope.keyDerivation == "iterated-SHA256-v1",
      envelope.iterations >= 10_000,
      let salt = Data(base64Encoded: envelope.saltBase64),
      let combined = Data(base64Encoded: envelope.sealedDataBase64),
      let sealedBox = try? AES.GCM.SealedBox(combined: combined)
    else { throw PortableDataError.invalidArchive }
    let key = deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
    guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
      throw PortableDataError.authenticationFailed
    }
    return try decodeArchive(plaintext)
  }

  public func previewRestore(_ archive: PortableArchive) -> RestorePreview {
    var warnings: [String] = []
    if archive.manifest.debitTotalYen != archive.manifest.creditTotalYen {
      warnings.append("仕訳全体の借方・貸方合計が一致しません")
    }
    if archive.manifest.evidenceCount != archive.evidence.count {
      warnings.append("マニフェストと証憑件数が一致しません")
    }
    let compatible =
      archive.manifest.formatVersion <= BlueprintVersions.dataFormat
      && archive.manifest.databaseSchemaVersion <= BlueprintVersions.databaseSchema
    if !compatible { warnings.append("このアプリより新しい形式のバックアップです") }
    return RestorePreview(manifest: archive.manifest, isCompatible: compatible, warnings: warnings)
  }

  public func restore(_ archive: PortableArchive, to destinationRoot: URL) throws {
    try validateCompatibility(archive.manifest)
    if fileManager.fileExists(atPath: destinationRoot.path),
      !(try fileManager.contentsOfDirectory(atPath: destinationRoot.path)).isEmpty
    {
      throw PortableDataError.destinationNotEmpty
    }
    let staging = destinationRoot.deletingLastPathComponent().appendingPathComponent(
      ".blueprint-restore-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    let layout = StorageLayout(root: staging)
    try layout.createDirectories(fileManager: fileManager)
    guard let databaseData = Data(base64Encoded: archive.databaseSnapshotBase64) else {
      throw PortableDataError.invalidArchive
    }
    try databaseData.write(to: layout.databaseURL, options: .atomic)
    for item in archive.evidence {
      guard let data = Data(base64Encoded: item.dataBase64) else {
        throw PortableDataError.invalidArchive
      }
      guard Self.sha256(data) == item.sha256 else {
        throw PortableDataError.evidenceHashMismatch(path: item.relativePath)
      }
      let url = staging.appendingPathComponent(item.relativePath)
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
    let verification = try SQLiteConnection(databaseURL: layout.databaseURL)
    let result = try verification.query("PRAGMA integrity_check").first?.values.first?.string
    guard result == "ok" else {
      throw PortableDataError.databaseIntegrityFailure(result ?? "no result")
    }
    let restoredArchive = try PortableDataService(
      connection: verification,
      root: staging,
      fileManager: fileManager
    ).makeArchive(createdAt: archive.manifest.createdAt)
    guard restoredArchive.manifest.tableRowCounts == archive.manifest.tableRowCounts,
      restoredArchive.manifest.debitTotalYen == archive.manifest.debitTotalYen,
      restoredArchive.manifest.creditTotalYen == archive.manifest.creditTotalYen,
      restoredArchive.manifest.evidenceHashes == archive.manifest.evidenceHashes
    else { throw PortableDataError.invalidArchive }
    if fileManager.fileExists(atPath: destinationRoot.path) {
      try fileManager.removeItem(at: destinationRoot)
    }
    try fileManager.moveItem(at: staging, to: destinationRoot)
  }

  public func writeAutomaticBackup(
    passphrase: String,
    directory: URL,
    retainGenerations: Int = 7,
    createdAt: Date = Date()
  ) throws -> URL {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: createdAt).replacingOccurrences(of: ":", with: "-")
    let destination = directory.appendingPathComponent("blueprint.\(timestamp).blueprintbackup")
    try makeEncryptedBackup(passphrase: passphrase, createdAt: createdAt).write(
      to: destination, options: .atomic)
    let backups = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "blueprintbackup" }
      .sorted { lhs, rhs in
        let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        return (left ?? .distantPast) > (right ?? .distantPast)
      }
    for expired in backups.dropFirst(max(1, retainGenerations)) {
      try fileManager.removeItem(at: expired)
    }
    return destination
  }

  public func diagnose(createdAt: Date = Date()) throws -> DiagnosticReport {
    var findings: [DiagnosticFinding] = []
    let integrity = try connection.query("PRAGMA integrity_check").first?.values.first?.string
    if integrity == "ok" {
      findings.append(
        DiagnosticFinding(
          severity: .information,
          title: "データベース整合性",
          detail: "SQLite integrity_check は正常です"
        ))
    } else {
      findings.append(
        DiagnosticFinding(
          severity: .error,
          title: "データベース破損の可能性",
          detail: integrity ?? "診断結果を取得できません"
        ))
    }
    let tableNames = try connection.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0["name"]?.string }
    var rowCounts: [String: Int] = [:]
    for table in tableNames where table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
      rowCounts[table] = Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)") ?? 0)
    }
    let evidenceRows = try connection.query(
      "SELECT original_relative_path, original_sha256 FROM evidence_documents ORDER BY original_relative_path"
    )
    var evidenceChecked = 0
    for row in evidenceRows {
      guard let relativePath = row["original_relative_path"]?.string,
        let expectedHash = row["original_sha256"]?.string
      else { continue }
      let url = root.appendingPathComponent("Evidence/Originals/\(relativePath)")
      guard let data = try? Data(contentsOf: url), Self.sha256(data) == expectedHash else {
        findings.append(
          DiagnosticFinding(
            severity: .error,
            title: "証憑原本の欠落またはハッシュ不一致",
            detail: "Evidence/Originals/\(relativePath)"
          ))
        continue
      }
      evidenceChecked += 1
    }
    let recordedEvidence = rowCounts["evidence_documents"] ?? 0
    if recordedEvidence != evidenceChecked {
      findings.append(
        DiagnosticFinding(
          severity: .warning,
          title: "証憑索引と原本の件数差",
          detail: "索引 \(recordedEvidence)件 / 検証済み原本 \(evidenceChecked)件"
        ))
    }
    let debit =
      try connection.scalarInt(
        "SELECT COALESCE(SUM(amount_yen), 0) FROM journal_lines WHERE side = 'debit'") ?? 0
    let credit =
      try connection.scalarInt(
        "SELECT COALESCE(SUM(amount_yen), 0) FROM journal_lines WHERE side = 'credit'") ?? 0
    if debit != credit {
      findings.append(
        DiagnosticFinding(
          severity: .error,
          title: "仕訳残高不一致",
          detail: "借方 \(debit)円 / 貸方 \(credit)円"
        ))
    }
    return DiagnosticReport(
      createdAt: createdAt,
      findings: findings,
      tableRowCounts: rowCounts,
      evidenceChecked: evidenceChecked
    )
  }

  private func makeTable(_ name: String) throws -> PortableTable {
    guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
      throw PortableDataError.invalidArchive
    }
    let columns = try connection.query("PRAGMA table_info(\(name))")
      .compactMap { $0["name"]?.string }
    let rows = try connection.query("SELECT * FROM \(name)").map { row in
      row.mapValues { value -> PortableValue in
        switch value {
        case .integer(let value): .integer(value)
        case .real(let value): .real(value)
        case .text(let value): .text(value)
        case .blob(let value): .blobBase64(value.base64EncodedString())
        case .null: .null
        }
      }
    }
    return PortableTable(name: name, columns: columns, rows: rows)
  }

  private func makeCSV(_ table: PortableTable) -> String {
    let header = table.columns.map(escapeCSV).joined(separator: ",")
    let body = table.rows.map { row in
      table.columns.map { column in
        let text: String
        switch row[column] ?? .null {
        case .integer(let value): text = String(value)
        case .real(let value): text = String(value)
        case .text(let value): text = value
        case .blobBase64(let value): text = value
        case .null: text = ""
        }
        return escapeCSV(text)
      }.joined(separator: ",")
    }
    return ([header] + body).joined(separator: "\r\n") + "\r\n"
  }

  private func escapeCSV(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
      return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
  }

  private func makeEvidenceArchive() throws -> [PortableEvidence] {
    let rows = try connection.query(
      "SELECT original_relative_path, original_sha256, byte_count FROM evidence_documents ORDER BY original_relative_path"
    )
    return try rows.map { row in
      guard
        let relativePath = row["original_relative_path"]?.string,
        let expectedHash = row["original_sha256"]?.string,
        let byteCount = row["byte_count"]?.int64
      else { throw PortableDataError.invalidArchive }
      let portablePath = "Evidence/Originals/\(relativePath)"
      let url = root.appendingPathComponent(portablePath)
      let data = try Data(contentsOf: url)
      let actualHash = Self.sha256(data)
      guard actualHash == expectedHash else {
        throw PortableDataError.evidenceHashMismatch(path: portablePath)
      }
      return PortableEvidence(
        relativePath: portablePath,
        sha256: actualHash,
        byteCount: byteCount,
        dataBase64: data.base64EncodedString()
      )
    }
  }

  private func validateCompatibility(_ manifest: TransferManifest) throws {
    guard manifest.formatName == "blueprint-portable-archive" else {
      throw PortableDataError.invalidArchive
    }
    guard manifest.formatVersion <= BlueprintVersions.dataFormat else {
      throw PortableDataError.incompatibleVersion(
        found: manifest.formatVersion,
        supported: BlueprintVersions.dataFormat
      )
    }
    guard manifest.databaseSchemaVersion <= BlueprintVersions.databaseSchema else {
      throw PortableDataError.incompatibleVersion(
        found: manifest.databaseSchemaVersion,
        supported: BlueprintVersions.databaseSchema
      )
    }
  }

  private func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
    var material = Data(passphrase.utf8) + salt
    for counter in 0..<iterations {
      var bigEndian = UInt64(counter).bigEndian
      withUnsafeBytes(of: &bigEndian) { material.append(contentsOf: $0) }
      material = Data(SHA256.hash(data: material))
    }
    return SymmetricKey(data: material)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
