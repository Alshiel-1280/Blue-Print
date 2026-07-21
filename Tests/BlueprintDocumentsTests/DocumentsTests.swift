import BlueprintDomain
import Foundation
import XCTest

@testable import BlueprintDocuments

final class DocumentsTests: XCTestCase {
  func testOriginalIsImmutableAndDerivedDataIsSeparated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("receipt.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original receipt".utf8).write(to: source)
    let store = EvidenceFileStore(
      originalsDirectory: root.appendingPathComponent("Originals"),
      derivedDirectory: root.appendingPathComponent("Derived")
    )
    let id = UUID()
    let stored = try store.importOriginal(from: source, documentID: id, mimeType: "text/plain")
    let originalURL = store.originalURL(relativePath: stored.relativePath)
    let before = try store.fingerprint(originalURL)
    _ = try store.writeDerived(Data("ocr result".utf8), evidenceID: id, name: "ocr.txt")
    let after = try store.fingerprint(originalURL)

    XCTAssertEqual(before.sha256, after.sha256)
    XCTAssertEqual(try Data(contentsOf: originalURL), Data("original receipt".utf8))
    XCTAssertThrowsError(
      try store.importOriginal(from: source, documentID: id, mimeType: "text/plain")
    ) { error in
      XCTAssertEqual(error as? EvidenceError, .originalMutationForbidden)
    }
  }

  func testOCRExtractorReturnsIndependentFieldsWithConfidence() {
    let evidenceID = UUID()
    let candidates = OCRCandidateExtractor.extract(
      evidenceID: evidenceID,
      lines: [
        RecognizedTextLine(text: "成城石井 渋谷店", confidence: 0.94),
        RecognizedTextLine(text: "2026年7月21日", confidence: 0.91),
        RecognizedTextLine(text: "合計 ￥12,480", confidence: 0.98),
        RecognizedTextLine(text: "T1234567890123 10%", confidence: 0.88),
      ]
    )

    XCTAssertTrue(candidates.contains { $0.field == .counterparty && $0.rawValue == "成城石井 渋谷店" })
    XCTAssertTrue(candidates.contains { $0.field == .transactionDate })
    XCTAssertTrue(candidates.contains { $0.field == .amount })
    XCTAssertTrue(candidates.contains { $0.field == .invoiceRegistrationNumber })
    XCTAssertTrue(candidates.contains { $0.field == .taxRate })
    XCTAssertTrue(candidates.allSatisfy { (0...1).contains($0.confidence) })
  }

  func testExactAndNearDuplicateEvidenceCandidates() {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let original = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "same",
      originalRelativePath: "one.pdf",
      originalFilename: "one.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .electronicTransaction,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井"
    )
    let exact = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "same",
      originalRelativePath: "two.pdf",
      originalFilename: "two.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .electronicTransaction
    )
    let near = EvidenceDocument(
      metadata: EntityMetadata(createdAt: now),
      originalSHA256: "different",
      originalRelativePath: "three.pdf",
      originalFilename: "three.pdf",
      mimeType: "application/pdf",
      byteCount: 100,
      acquiredAt: now,
      origin: .electronicTransaction,
      transactionDate: now,
      amount: Money(yen: 12_480),
      counterparty: "成城石井"
    )
    let results = EvidenceDuplicateDetector.candidates(for: original, among: [exact, near])
    XCTAssertEqual(results.first?.score, 1)
    XCTAssertEqual(results.last?.score, 1)
    XCTAssertTrue(results.contains { $0.reasons.contains("原本ハッシュ一致") })
  }
}
