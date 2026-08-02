import CryptoKit
import Foundation

public struct SignedUpdateManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let version: String
  public let downloadURL: URL
  public let artifactSHA256: String
  public let publishedAt: String
  public let keyID: String
  public let signatureBase64: String

  public init(
    schemaVersion: Int = 1,
    version: String,
    downloadURL: URL,
    artifactSHA256: String,
    publishedAt: String,
    keyID: String,
    signatureBase64: String
  ) {
    self.schemaVersion = schemaVersion
    self.version = version
    self.downloadURL = downloadURL
    self.artifactSHA256 = artifactSHA256
    self.publishedAt = publishedAt
    self.keyID = keyID
    self.signatureBase64 = signatureBase64
  }

  public var signedPayload: Data {
    Data(
      [
        String(schemaVersion),
        version,
        downloadURL.absoluteString,
        artifactSHA256.lowercased(),
        publishedAt,
        keyID,
      ].joined(separator: "\n").utf8
    )
  }
}

public enum ManualUpdateResult: Equatable, Sendable {
  case upToDate
  case updateAvailable(SignedUpdateManifest)
}

public enum ManualUpdateError: Error, Equatable, Sendable {
  case invalidResponse
  case unsupportedSchema
  case invalidArtifactHash
  case insecureDownloadURL
  case unknownKey
  case invalidSignature
  case invalidVersion
}

public struct ManualUpdateService: Sendable {
  public typealias Loader = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

  private let manifestURL: URL
  private let currentVersion: String
  private let keyID: String
  private let publicKey: Data
  private let loader: Loader

  public init(
    manifestURL: URL,
    currentVersion: String,
    keyID: String,
    publicKey: Data,
    loader: @escaping Loader = { url in
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let response = response as? HTTPURLResponse else {
        throw ManualUpdateError.invalidResponse
      }
      return (data, response)
    }
  ) {
    self.manifestURL = manifestURL
    self.currentVersion = currentVersion
    self.keyID = keyID
    self.publicKey = publicKey
    self.loader = loader
  }

  public func check() async throws -> ManualUpdateResult {
    let (data, response) = try await loader(manifestURL)
    guard response.statusCode == 200,
      let manifest = try? JSONDecoder().decode(SignedUpdateManifest.self, from: data)
    else {
      throw ManualUpdateError.invalidResponse
    }
    guard manifest.schemaVersion == 1 else { throw ManualUpdateError.unsupportedSchema }
    guard manifest.keyID == keyID else { throw ManualUpdateError.unknownKey }
    guard manifest.downloadURL.scheme == "https" else {
      throw ManualUpdateError.insecureDownloadURL
    }
    let hash = manifest.artifactSHA256.lowercased()
    guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
      throw ManualUpdateError.invalidArtifactHash
    }
    guard
      let signature = Data(base64Encoded: manifest.signatureBase64),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
      key.isValidSignature(signature, for: manifest.signedPayload)
    else {
      throw ManualUpdateError.invalidSignature
    }
    guard let current = SemanticVersion(currentVersion),
      let candidate = SemanticVersion(manifest.version)
    else {
      throw ManualUpdateError.invalidVersion
    }
    return candidate > current ? .updateAvailable(manifest) : .upToDate
  }
}

private struct SemanticVersion: Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ value: String) {
    let core = value.split(separator: "-", maxSplits: 1).first ?? ""
    let parts = core.split(separator: ".")
    guard parts.count == 3,
      let major = Int(parts[0]),
      let minor = Int(parts[1]),
      let patch = Int(parts[2])
    else { return nil }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
