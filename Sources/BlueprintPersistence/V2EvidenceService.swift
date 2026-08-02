import BlueprintDocuments
import BlueprintDomain
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum V2EvidenceServiceError: Error, Equatable, Sendable {
  case duplicate(existingID: UUID)
  case unsupportedFile
}

public struct V2EvidenceImportResult: Sendable {
  public let document: EvidenceDocument
  public let candidates: [OCRCandidate]
  public let job: JobRecord
}

public struct V2EvidenceService: Sendable {
  private let recognizer: any OCRRecognizing

  public init(recognizer: any OCRRecognizing = OnDeviceOCRPipeline()) {
    self.recognizer = recognizer
  }

  public func importAndRecognize(
    sourceURL: URL,
    origin: EvidenceOrigin,
    fiscalYearID: UUID?,
    database: V2Database,
    at date: Date = Date()
  ) async throws -> V2EvidenceImportResult {
    let data = try Data(contentsOf: sourceURL)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    if let existing = try await database.evidenceDocuments()
      .first(where: { $0.originalSHA256 == hash })
    {
      throw V2EvidenceServiceError.duplicate(existingID: existing.id)
    }
    let fileExtension = sourceURL.pathExtension.lowercased()
    guard ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(fileExtension) else {
      throw V2EvidenceServiceError.unsupportedFile
    }
    let id = UUID()
    let storedFilename = fileExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(fileExtension)"
    let destination = database.layout.evidenceOriginalsDirectory
      .appendingPathComponent(storedFilename)
    try data.write(to: destination, options: .atomic)
    let mimeType =
      UTType(filenameExtension: fileExtension)?.preferredMIMEType
      ?? "application/octet-stream"
    var document = EvidenceDocument(
      metadata: EntityMetadata(id: id, createdAt: date),
      originalSHA256: hash,
      originalRelativePath: "Evidence/Originals/\(storedFilename)",
      originalFilename: sourceURL.lastPathComponent,
      mimeType: mimeType,
      byteCount: Int64(data.count),
      acquiredAt: date,
      origin: origin
    )
    try await database.saveEvidence(document, fiscalYearID: fiscalYearID)
    let job = JobRecord(
      idempotencyKey: "ocr:\(hash)",
      kind: .ocr,
      createdAt: date,
      updatedAt: date
    )
    try await database.enqueue(job)
    do {
      try await database.updateJob(
        id: job.id,
        state: .running,
        progressBasisPoints: 1_000,
        checkpoint: "original-stored",
        at: date
      )
      let lines = try recognizer.recognize(url: destination)
      let candidates = OCRCandidateExtractor.extract(evidenceID: id, lines: lines)
      try await database.saveOCRCandidates(candidates)
      document.transactionDate = candidates.first { $0.field == .transactionDate }
        .flatMap { Self.parseDate($0.correctedValue ?? $0.rawValue) }
      document.amount = candidates.first { $0.field == .amount }
        .flatMap { Self.parseAmount($0.correctedValue ?? $0.rawValue) }
        .map(Money.init(yen:))
      document.counterparty = candidates.first { $0.field == .counterparty }
        .map { $0.correctedValue ?? $0.rawValue }
      document.state = .needsReview
      document.metadata.touch(at: Date())
      let snapshot = try JSONSerialization.data(
        withJSONObject: lines.map {
          ["text": $0.text, "confidence": $0.confidence] as [String: Any]
        },
        options: [.sortedKeys]
      )
      try await database.saveEvidence(
        document,
        fiscalYearID: fiscalYearID,
        ocrSnapshotJSON: String(decoding: snapshot, as: UTF8.self)
      )
      try await database.updateJob(
        id: job.id,
        state: .succeeded,
        progressBasisPoints: 10_000,
        checkpoint: "candidates:\(candidates.count)",
        at: Date()
      )
      return V2EvidenceImportResult(document: document, candidates: candidates, job: job)
    } catch {
      try? await database.updateJob(
        id: job.id,
        state: .failed,
        progressBasisPoints: 1_000,
        checkpoint: "original-stored",
        failureReason: String(describing: error),
        at: Date()
      )
      throw error
    }
  }

  private static func parseDate(_ value: String) -> Date? {
    for format in ["yyyy/MM/dd", "yyyy-MM-dd", "yyyy年M月d日"] {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "ja_JP_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }

  private static func parseAmount(_ value: String) -> Int64? {
    Int64(value.filter { $0.isNumber || $0 == "-" })
  }
}
