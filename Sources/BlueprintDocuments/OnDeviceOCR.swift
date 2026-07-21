import BlueprintDomain
import Foundation
import ImageIO
import PDFKit
import Vision

public struct RecognizedTextLine: Equatable, Sendable {
  public let text: String
  public let confidence: Double

  public init(text: String, confidence: Double) {
    self.text = text
    self.confidence = confidence
  }
}

public protocol OCRRecognizing: Sendable {
  func recognize(url: URL) throws -> [RecognizedTextLine]
}

public final class OnDeviceOCRPipeline: OCRRecognizing, @unchecked Sendable {
  public init() {}

  public func recognize(url: URL) throws -> [RecognizedTextLine] {
    let images = try images(from: url)
    guard !images.isEmpty else { throw EvidenceError.unsupportedFile }
    var result: [RecognizedTextLine] = []
    for image in images {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["ja-JP", "en-US"]
      try VNImageRequestHandler(cgImage: image).perform([request])
      for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        result.append(
          RecognizedTextLine(
            text: candidate.string,
            confidence: Double(candidate.confidence)
          ))
      }
    }
    return result
  }

  private func images(from url: URL) throws -> [CGImage] {
    if url.pathExtension.lowercased() == "pdf" {
      guard let document = PDFDocument(url: url) else { throw EvidenceError.unreadableFile }
      return (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 2_000, height: 2_800), for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
      }
    }
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw EvidenceError.unsupportedFile }
    return [image]
  }
}

public enum OCRCandidateExtractor {
  public static func extract(
    evidenceID: EntityID,
    lines: [RecognizedTextLine]
  ) -> [OCRCandidate] {
    var candidates: [OCRCandidate] = []
    for line in lines {
      if let date = firstMatch(
        in: line.text,
        pattern: #"(?:20\d{2})[./年-](?:0?[1-9]|1[0-2])[./月-](?:0?[1-9]|[12]\d|3[01])日?"#
      ) {
        candidates.append(
          OCRCandidate(
            evidenceID: evidenceID,
            field: .transactionDate,
            rawValue: date,
            confidence: line.confidence
          ))
      }
      if let amount = firstMatch(
        in: line.text,
        pattern: #"(?:合計|税込|金額)?\s*[¥￥]?\s*\d{1,3}(?:,\d{3})+|[¥￥]\s*\d+"#
      ) {
        candidates.append(
          OCRCandidate(
            evidenceID: evidenceID,
            field: .amount,
            rawValue: amount,
            confidence: line.confidence
          ))
      }
      if let registration = firstMatch(in: line.text, pattern: #"T\d{13}"#) {
        candidates.append(
          OCRCandidate(
            evidenceID: evidenceID,
            field: .invoiceRegistrationNumber,
            rawValue: registration,
            confidence: line.confidence
          ))
      }
      if let rate = firstMatch(in: line.text, pattern: #"(?:10|8)\s*%"#) {
        candidates.append(
          OCRCandidate(
            evidenceID: evidenceID,
            field: .taxRate,
            rawValue: rate,
            confidence: line.confidence
          ))
      }
    }
    if let merchant = lines.first(where: { line in
      !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && firstMatch(in: line.text, pattern: #"\d{3,}"#) == nil
    }) {
      candidates.append(
        OCRCandidate(
          evidenceID: evidenceID,
          field: .counterparty,
          rawValue: merchant.text,
          confidence: merchant.confidence
        ))
    }
    return deduplicated(candidates)
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: range),
      let swiftRange = Range(match.range, in: text)
    else { return nil }
    return String(text[swiftRange])
  }

  private static func deduplicated(_ candidates: [OCRCandidate]) -> [OCRCandidate] {
    var seen: Set<String> = []
    return candidates.filter {
      seen.insert("\($0.field.rawValue)|\($0.rawValue)").inserted
    }
  }
}
