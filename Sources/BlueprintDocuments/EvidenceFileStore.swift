import CryptoKit
import Foundation

public struct StoredEvidenceOriginal: Equatable, Sendable {
  public let sha256: String
  public let relativePath: String
  public let byteCount: Int64
  public let mimeType: String
}

public struct EvidenceFileStore: Sendable {
  public let originalsDirectory: URL
  public let derivedDirectory: URL

  public init(originalsDirectory: URL, derivedDirectory: URL) {
    self.originalsDirectory = originalsDirectory
    self.derivedDirectory = derivedDirectory
  }

  public func importOriginal(
    from source: URL,
    documentID: UUID,
    mimeType: String
  ) throws -> StoredEvidenceOriginal {
    let fingerprint = try fingerprint(source)
    let data = try Data(contentsOf: source, options: .mappedIfSafe)
    let extensionPart = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
    let relative = "\(documentID.uuidString.lowercased()).\(extensionPart)"
    let destination = originalsDirectory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: originalsDirectory,
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      throw EvidenceError.originalMutationForbidden
    }
    do {
      try data.write(to: destination, options: .withoutOverwriting)
    } catch {
      throw EvidenceError.originalMutationForbidden
    }
    return StoredEvidenceOriginal(
      sha256: fingerprint.sha256,
      relativePath: relative,
      byteCount: fingerprint.byteCount,
      mimeType: mimeType
    )
  }

  public func importOriginal(
    data: Data,
    documentID: UUID,
    fileExtension: String,
    mimeType: String
  ) throws -> StoredEvidenceOriginal {
    guard !data.isEmpty else { throw EvidenceError.unreadableFile }
    let normalizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let relative =
      "\(documentID.uuidString.lowercased()).\(normalizedExtension.isEmpty ? "bin" : normalizedExtension.lowercased())"
    let destination = originalsDirectory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: originalsDirectory,
      withIntermediateDirectories: true
    )
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw EvidenceError.originalMutationForbidden
    }
    do {
      try data.write(to: destination, options: .withoutOverwriting)
    } catch {
      throw EvidenceError.originalMutationForbidden
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return StoredEvidenceOriginal(
      sha256: digest,
      relativePath: relative,
      byteCount: Int64(data.count),
      mimeType: mimeType
    )
  }

  public func fingerprint(_ source: URL) throws -> (sha256: String, byteCount: Int64) {
    let data: Data
    do {
      data = try Data(contentsOf: source, options: .mappedIfSafe)
    } catch {
      throw EvidenceError.unreadableFile
    }
    guard !data.isEmpty else { throw EvidenceError.unreadableFile }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (digest, Int64(data.count))
  }

  public func fingerprint(_ data: Data) throws -> (sha256: String, byteCount: Int64) {
    guard !data.isEmpty else { throw EvidenceError.unreadableFile }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (digest, Int64(data.count))
  }

  public func writeDerived(
    _ data: Data,
    evidenceID: UUID,
    name: String
  ) throws -> String {
    let directory = derivedDirectory.appendingPathComponent(
      evidenceID.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(name)
    try data.write(to: destination, options: .atomic)
    return "\(evidenceID.uuidString.lowercased())/\(name)"
  }

  public func originalURL(relativePath: String) -> URL {
    originalsDirectory.appendingPathComponent(relativePath)
  }
}
