import CryptoKit
import XCTest

@testable import BlueprintTransfer

final class ManualUpdateServiceTests: XCTestCase {
  func testSignedManifestReportsAvailableUpdate() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let unsigned = SignedUpdateManifest(
      version: "2.1.0",
      downloadURL: URL(string: "https://example.com/BluePrint.dmg")!,
      artifactSHA256: String(repeating: "a", count: 64),
      publishedAt: "2026-07-29T00:00:00Z",
      keyID: "test",
      signatureBase64: ""
    )
    let manifest = SignedUpdateManifest(
      version: unsigned.version,
      downloadURL: unsigned.downloadURL,
      artifactSHA256: unsigned.artifactSHA256,
      publishedAt: unsigned.publishedAt,
      keyID: unsigned.keyID,
      signatureBase64: try key.signature(for: unsigned.signedPayload).base64EncodedString()
    )
    let data = try JSONEncoder().encode(manifest)
    let service = ManualUpdateService(
      manifestURL: URL(string: "https://example.com/update.json")!,
      currentVersion: "2.0.0",
      keyID: "test",
      publicKey: key.publicKey.rawRepresentation,
      loader: { url in
        (
          data,
          HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!
        )
      }
    )

    let result = try await service.check()
    XCTAssertEqual(result, .updateAvailable(manifest))
  }

  func testManifestRejectsInvalidSignatureAndHTTPDownload() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let manifest = SignedUpdateManifest(
      version: "2.1.0",
      downloadURL: URL(string: "http://example.com/BluePrint.dmg")!,
      artifactSHA256: String(repeating: "a", count: 64),
      publishedAt: "2026-07-29T00:00:00Z",
      keyID: "test",
      signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
    )
    let data = try JSONEncoder().encode(manifest)
    let service = ManualUpdateService(
      manifestURL: URL(string: "https://example.com/update.json")!,
      currentVersion: "2.0.0",
      keyID: "test",
      publicKey: key.publicKey.rawRepresentation,
      loader: { url in
        (
          data,
          HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!
        )
      }
    )

    do {
      _ = try await service.check()
      XCTFail("Expected insecure URL rejection")
    } catch {
      XCTAssertEqual(error as? ManualUpdateError, .insecureDownloadURL)
    }
  }
}
