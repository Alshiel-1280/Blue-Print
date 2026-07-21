import BlueprintDomain
import Foundation

public enum EvidenceOrigin: String, Codable, CaseIterable, Sendable {
  case paperScan
  case electronicTransaction
  case cameraCapture
}

public enum EvidenceState: String, Codable, CaseIterable, Sendable {
  case unprocessed
  case needsReview
  case posted
  case excluded
}

public enum EvidenceError: Error, Equatable, Sendable {
  case unsupportedFile
  case unreadableFile
  case exactDuplicate(existingID: EntityID)
  case originalMutationForbidden
  case confirmationRequired
  case invalidCandidate
}

public struct EvidenceDocument: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let originalSHA256: String
  public let originalRelativePath: String
  public let originalFilename: String
  public let mimeType: String
  public let byteCount: Int64
  public let acquiredAt: Date
  public let origin: EvidenceOrigin
  public var state: EvidenceState
  public var transactionDate: Date?
  public var amount: Money?
  public var counterparty: String?
  public var electronicTransaction: Bool

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    originalSHA256: String,
    originalRelativePath: String,
    originalFilename: String,
    mimeType: String,
    byteCount: Int64,
    acquiredAt: Date,
    origin: EvidenceOrigin,
    state: EvidenceState = .unprocessed,
    transactionDate: Date? = nil,
    amount: Money? = nil,
    counterparty: String? = nil,
    electronicTransaction: Bool? = nil
  ) {
    self.metadata = metadata
    self.originalSHA256 = originalSHA256
    self.originalRelativePath = originalRelativePath
    self.originalFilename = originalFilename
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.acquiredAt = acquiredAt
    self.origin = origin
    self.state = state
    self.transactionDate = transactionDate
    self.amount = amount
    self.counterparty = counterparty
    self.electronicTransaction = electronicTransaction ?? (origin == .electronicTransaction)
  }
}

public struct EvidenceLink: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let evidenceID: EntityID
  public let journalEntryID: EntityID
  public let linkedAt: Date

  public init(
    id: EntityID = UUID(),
    evidenceID: EntityID,
    journalEntryID: EntityID,
    linkedAt: Date
  ) {
    self.id = id
    self.evidenceID = evidenceID
    self.journalEntryID = journalEntryID
    self.linkedAt = linkedAt
  }
}

public enum OCRField: String, Codable, CaseIterable, Sendable {
  case transactionDate
  case amount
  case counterparty
  case invoiceRegistrationNumber
  case taxRate
}

public struct OCRCandidate: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let evidenceID: EntityID
  public let field: OCRField
  public let rawValue: String
  public let confidence: Double
  public var correctedValue: String?
  public var correctedAt: Date?

  public init(
    id: EntityID = UUID(),
    evidenceID: EntityID,
    field: OCRField,
    rawValue: String,
    confidence: Double,
    correctedValue: String? = nil,
    correctedAt: Date? = nil
  ) {
    self.id = id
    self.evidenceID = evidenceID
    self.field = field
    self.rawValue = rawValue
    self.confidence = min(max(confidence, 0), 1)
    self.correctedValue = correctedValue
    self.correctedAt = correctedAt
  }

  public var effectiveValue: String { correctedValue ?? rawValue }
}

public struct EvidenceSearch: Equatable, Sendable {
  public var dateRange: ClosedRange<Date>?
  public var amount: Money?
  public var counterparty: String?
  public var states: Set<EvidenceState>
  public var electronicOnly: Bool

  public init(
    dateRange: ClosedRange<Date>? = nil,
    amount: Money? = nil,
    counterparty: String? = nil,
    states: Set<EvidenceState> = Set(EvidenceState.allCases),
    electronicOnly: Bool = false
  ) {
    self.dateRange = dateRange
    self.amount = amount
    self.counterparty = counterparty
    self.states = states
    self.electronicOnly = electronicOnly
  }
}

public struct DuplicateEvidenceCandidate: Equatable, Sendable {
  public let evidenceID: EntityID
  public let score: Double
  public let reasons: [String]
}

public enum EvidenceDuplicateDetector {
  public static func candidates(
    for document: EvidenceDocument,
    among existing: [EvidenceDocument]
  ) -> [DuplicateEvidenceCandidate] {
    existing.compactMap { candidate in
      if candidate.originalSHA256 == document.originalSHA256 {
        return DuplicateEvidenceCandidate(
          evidenceID: candidate.id,
          score: 1,
          reasons: ["原本ハッシュ一致"]
        )
      }
      var score = 0.0
      var reasons: [String] = []
      if candidate.transactionDate == document.transactionDate, document.transactionDate != nil {
        score += 0.35
        reasons.append("日付一致")
      }
      if candidate.amount == document.amount, document.amount != nil {
        score += 0.4
        reasons.append("金額一致")
      }
      if let lhs = candidate.counterparty?.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
        let rhs = document.counterparty?.folding(
          options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
        lhs == rhs
      {
        score += 0.25
        reasons.append("取引先一致")
      }
      guard score >= 0.6 else { return nil }
      return DuplicateEvidenceCandidate(
        evidenceID: candidate.id,
        score: score,
        reasons: reasons
      )
    }.sorted { $0.score > $1.score }
  }
}

public protocol EvidenceRepository: Sendable {
  func save(_ document: EvidenceDocument) throws
  func fetch(id: EntityID) throws -> EvidenceDocument?
  func search(_ query: EvidenceSearch) throws -> [EvidenceDocument]
  func appendCandidate(_ candidate: OCRCandidate) throws
  func candidates(evidenceID: EntityID) throws -> [OCRCandidate]
  func link(_ link: EvidenceLink) throws
  func links(evidenceID: EntityID) throws -> [EvidenceLink]
}
