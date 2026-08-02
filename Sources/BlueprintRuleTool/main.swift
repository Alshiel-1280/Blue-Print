import CryptoKit
import Foundation
import Security

private enum RuleSigningToolError: Error, CustomStringConvertible {
  case usage
  case keychain(OSStatus)
  case invalidKey
  case missingDirectory(String)
  case noPackages

  var description: String {
    switch self {
    case .usage:
      """
      usage:
        blueprint-rule-tool bootstrap-and-sign <RulePackages directory>
        blueprint-rule-tool sign-update-manifest <version> <DMG path> <HTTPS download URL> <output JSON>
      """
    case .keychain(let status):
      "Keychain operation failed with status \(status)"
    case .invalidKey:
      "The stored Ed25519 private key is invalid"
    case .missingDirectory(let path):
      "Rule package directory does not exist: \(path)"
    case .noPackages:
      "No rule package manifests were found"
    }
  }
}

private struct ReleaseUpdateManifest: Encodable {
  let schemaVersion: Int
  let version: String
  let downloadURL: URL
  let artifactSHA256: String
  let publishedAt: String
  let keyID: String
  let signatureBase64: String
}

private enum RuleSigningKeychain {
  static let service = "com.ryo1280.blueprint.rule-signing"
  static let account = "release-ed25519-v1"

  static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
      guard let data = result as? Data,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
      else {
        throw RuleSigningToolError.invalidKey
      }
      return key
    }
    guard status == errSecItemNotFound else {
      throw RuleSigningToolError.keychain(status)
    }

    let key = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: key.rawRepresentation,
      kSecAttrLabel as String: "Blue-Print rule package release signing key",
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw RuleSigningToolError.keychain(addStatus)
    }
    return key
  }
}

private func bootstrapAndSign(root: URL) throws {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else {
    throw RuleSigningToolError.missingDirectory(root.path)
  }

  let key = try RuleSigningKeychain.loadOrCreate()
  let publicKey = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
  try Data(publicKey.utf8).write(
    to: root.appendingPathComponent("trusted-key.b64"),
    options: .atomic
  )

  let children = try FileManager.default.contentsOfDirectory(
    at: root,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  )
  var signedPackages: [String] = []
  for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      continue
    }
    let manifestURL = child.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
    let manifest = try Data(contentsOf: manifestURL)
    let signature = try key.signature(for: manifest)
    let encoded = signature.base64EncodedString() + "\n"
    try Data(encoded.utf8).write(
      to: child.appendingPathComponent("signature.ed25519"),
      options: .atomic
    )
    signedPackages.append(child.lastPathComponent)
  }
  guard !signedPackages.isEmpty else { throw RuleSigningToolError.noPackages }
  print("Signed bundled rule packages: \(signedPackages.joined(separator: ", "))")
  print("Private key remains in macOS Keychain service \(RuleSigningKeychain.service).")
}

private func signUpdateManifest(
  version: String,
  artifactURL: URL,
  downloadURL: URL,
  outputURL: URL
) throws {
  guard downloadURL.scheme == "https" else { throw RuleSigningToolError.usage }
  let artifact = try Data(contentsOf: artifactURL)
  let hash = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
  let publishedAt = ISO8601DateFormatter().string(from: Date())
  let keyID = "bundled-v1.1"
  let schemaVersion = 1
  let payload = Data(
    [
      String(schemaVersion),
      version,
      downloadURL.absoluteString,
      hash,
      publishedAt,
      keyID,
    ].joined(separator: "\n").utf8
  )
  let key = try RuleSigningKeychain.loadOrCreate()
  let signature = try key.signature(for: payload).base64EncodedString()
  let manifest = ReleaseUpdateManifest(
    schemaVersion: schemaVersion,
    version: version,
    downloadURL: downloadURL,
    artifactSHA256: hash,
    publishedAt: publishedAt,
    keyID: keyID,
    signatureBase64: signature
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(manifest).write(to: outputURL, options: .atomic)
  print("Signed update manifest: \(outputURL.path)")
}

do {
  let arguments = CommandLine.arguments
  if arguments.count == 3, arguments[1] == "bootstrap-and-sign" {
    try bootstrapAndSign(root: URL(fileURLWithPath: arguments[2], isDirectory: true))
  } else if arguments.count == 6, arguments[1] == "sign-update-manifest",
    let downloadURL = URL(string: arguments[4])
  {
    try signUpdateManifest(
      version: arguments[2],
      artifactURL: URL(fileURLWithPath: arguments[3]),
      downloadURL: downloadURL,
      outputURL: URL(fileURLWithPath: arguments[5])
    )
  } else {
    throw RuleSigningToolError.usage
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
