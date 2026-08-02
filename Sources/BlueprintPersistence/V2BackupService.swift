import BlueprintTransfer
import CryptoKit
import Foundation

public enum V2BackupError: Error, Equatable, Sendable {
  case invalidEnvelope
  case authenticationFailed
  case incompatibleGeneration
  case invalidKeyDerivationParameters
  case hashMismatch(String)
  case unsafeRelativePath(String)
  case destinationNotEmpty
}

public struct V2BackupService: @unchecked Sendable {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func makeBackup(
    database: V2Database,
    passphrase: String,
    createdAt: Date = Date()
  ) async throws -> Data {
    let databaseData = try await database.databaseSnapshot()
    let layout = database.layout
    let payload = V2BackupPayload(
      createdAt: createdAt,
      databaseSHA256: Self.sha256(databaseData),
      databaseBase64: databaseData.base64EncodedString(),
      evidenceFiles: try evidenceFiles(in: layout.evidenceOriginalsDirectory)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    let keyData = try Argon2KeyDeriver().derive(passphrase: passphrase, salt: salt)
    let sealed = try AES.GCM.seal(payloadData, using: SymmetricKey(data: keyData))
    guard let combined = sealed.combined else { throw V2BackupError.invalidEnvelope }
    let envelope = BackupEnvelopeV2(
      kdf: Argon2idParameters(
        memoryKiB: Argon2KeyDeriver.defaultMemoryKiB,
        iterations: Argon2KeyDeriver.defaultIterations,
        parallelism: Argon2KeyDeriver.defaultParallelism,
        outputBytes: Argon2KeyDeriver.outputBytes,
        saltBase64: salt.base64EncodedString()
      ),
      sealedDataBase64: combined.base64EncodedString()
    )
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(envelope)
  }

  public func openBackup(
    _ data: Data,
    passphrase: String
  ) throws -> V2BackupPayload {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(BackupEnvelopeV2.self, from: data),
      envelope.formatName == "blueprint-v2-encrypted-backup",
      envelope.formatFamily == "blueprint-v2",
      envelope.formatVersion == 1,
      envelope.storageGeneration == 2,
      envelope.encryption == "AES-256-GCM",
      envelope.keyDerivation == "Argon2id-v19",
      envelope.kdf.version == Argon2KeyDeriver.version,
      let salt = Data(base64Encoded: envelope.kdf.saltBase64),
      let combined = Data(base64Encoded: envelope.sealedDataBase64),
      let sealed = try? AES.GCM.SealedBox(combined: combined)
    else {
      throw V2BackupError.invalidEnvelope
    }
    let keyData: Data
    do {
      keyData = try Argon2KeyDeriver().derive(
        passphrase: passphrase,
        salt: salt,
        memoryKiB: envelope.kdf.memoryKiB,
        iterations: envelope.kdf.iterations,
        parallelism: envelope.kdf.parallelism,
        outputBytes: envelope.kdf.outputBytes
      )
    } catch Argon2KeyDerivationError.invalidParameters {
      throw V2BackupError.invalidKeyDerivationParameters
    }
    guard
      let plaintext = try? AES.GCM.open(
        sealed,
        using: SymmetricKey(data: keyData)
      ),
      let payload = try? decoder.decode(V2BackupPayload.self, from: plaintext)
    else {
      throw V2BackupError.authenticationFailed
    }
    guard payload.storageGeneration == 2, payload.databaseSchemaVersion == 1 else {
      throw V2BackupError.incompatibleGeneration
    }
    guard let database = Data(base64Encoded: payload.databaseBase64),
      Self.sha256(database) == payload.databaseSHA256
    else {
      throw V2BackupError.hashMismatch("Database/blueprint-v2.sqlite")
    }
    for file in payload.evidenceFiles {
      guard let contents = Data(base64Encoded: file.dataBase64),
        Int64(contents.count) == file.byteCount,
        Self.sha256(contents) == file.sha256
      else {
        throw V2BackupError.hashMismatch(file.relativePath)
      }
      try Self.validate(relativePath: file.relativePath)
    }
    return payload
  }

  public func restore(
    _ payload: V2BackupPayload,
    to layout: V2StorageLayout
  ) throws {
    guard payload.storageGeneration == 2, payload.databaseSchemaVersion == 1 else {
      throw V2BackupError.incompatibleGeneration
    }
    if fileManager.fileExists(atPath: layout.root.path),
      !(try fileManager.contentsOfDirectory(atPath: layout.root.path)).isEmpty
    {
      throw V2BackupError.destinationNotEmpty
    }
    try layout.prepare(fileManager: fileManager)
    guard let database = Data(base64Encoded: payload.databaseBase64),
      Self.sha256(database) == payload.databaseSHA256
    else {
      throw V2BackupError.hashMismatch("Database/blueprint-v2.sqlite")
    }
    try database.write(to: layout.databaseURL, options: .atomic)
    for file in payload.evidenceFiles {
      try Self.validate(relativePath: file.relativePath)
      guard let contents = Data(base64Encoded: file.dataBase64),
        Self.sha256(contents) == file.sha256
      else {
        throw V2BackupError.hashMismatch(file.relativePath)
      }
      let destination = layout.root.appendingPathComponent(file.relativePath)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: destination, options: .atomic)
    }
  }

  private func evidenceFiles(in directory: URL) throws -> [V2BackupFile] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    var files: [V2BackupFile] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      let contents = try Data(contentsOf: url)
      let baseComponents = directory.standardizedFileURL.pathComponents
      let fileComponents = url.standardizedFileURL.pathComponents
      guard fileComponents.starts(with: baseComponents) else {
        throw V2BackupError.unsafeRelativePath(url.path)
      }
      let localPath = fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
      let relativePath = "Evidence/Originals/\(localPath)"
      files.append(
        V2BackupFile(
          relativePath: relativePath,
          sha256: Self.sha256(contents),
          byteCount: Int64(contents.count),
          dataBase64: contents.base64EncodedString()
        )
      )
    }
    return files.sorted { $0.relativePath < $1.relativePath }
  }

  private static func validate(relativePath: String) throws {
    let components = NSString(string: relativePath).pathComponents
    guard !relativePath.hasPrefix("/"),
      !components.contains(".."),
      relativePath.hasPrefix("Evidence/Originals/")
    else {
      throw V2BackupError.unsafeRelativePath(relativePath)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
