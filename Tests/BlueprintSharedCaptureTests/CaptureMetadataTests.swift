import XCTest

@testable import BlueprintSharedCapture

final class CaptureMetadataTests: XCTestCase {
  func testIdempotencyKeyCombinesDocumentAndHash() {
    let documentID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let metadata = CaptureSourceMetadata(
      documentID: documentID,
      originalSHA256: "ABCDEF",
      deviceID: "iphone-local-id",
      deviceKind: .iPhone,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      mimeType: "image/heic",
      byteCount: 1_024,
      transferState: .queued
    )

    XCTAssertEqual(
      metadata.idempotencyKey,
      "11111111-2222-4333-8444-555555555555:abcdef"
    )
    XCTAssertEqual(metadata.canonicalAuthority, .mac)
  }
}
