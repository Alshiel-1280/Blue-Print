import Foundation

public enum BlueprintStorageGeneration: Int, Codable, Sendable {
  case v2 = 2
}

public enum BackgroundJobKind: String, Codable, CaseIterable, Sendable {
  case ocr
  case dataImport
  case matching
  case backup
  case xtxGeneration
}

public enum BackgroundJobState: String, Codable, CaseIterable, Sendable {
  case queued
  case running
  case succeeded
  case failed
  case cancelled
}

public struct JobRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let idempotencyKey: String
  public let kind: BackgroundJobKind
  public var state: BackgroundJobState
  public var progressBasisPoints: Int
  public var checkpoint: String?
  public var failureReason: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    idempotencyKey: String,
    kind: BackgroundJobKind,
    state: BackgroundJobState = .queued,
    progressBasisPoints: Int = 0,
    checkpoint: String? = nil,
    failureReason: String? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.kind = kind
    self.state = state
    self.progressBasisPoints = min(max(progressBasisPoints, 0), 10_000)
    self.checkpoint = checkpoint
    self.failureReason = failureReason
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ImportCandidateV1: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sourceKind: String
  public let sourceFingerprint: String
  public let occurredAt: Date?
  public let amountYen: Int64?
  public let description: String
  public let warnings: [String]

  public init(
    id: UUID = UUID(),
    sourceKind: String,
    sourceFingerprint: String,
    occurredAt: Date?,
    amountYen: Int64?,
    description: String,
    warnings: [String] = []
  ) {
    self.id = id
    self.sourceKind = sourceKind
    self.sourceFingerprint = sourceFingerprint
    self.occurredAt = occurredAt
    self.amountYen = amountYen
    self.description = description
    self.warnings = warnings
  }
}

public enum ImportCandidateStateV2: String, Codable, CaseIterable, Sendable {
  case pending
  case matched
  case confirmed
  case excluded
}

public struct StoredImportCandidateV2: Codable, Equatable, Identifiable, Sendable {
  public let candidate: ImportCandidateV1
  public var state: ImportCandidateStateV2
  public let createdAt: Date
  public var updatedAt: Date

  public var id: UUID { candidate.id }

  public init(
    candidate: ImportCandidateV1,
    state: ImportCandidateStateV2 = .pending,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.candidate = candidate
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum MatchCandidateStateV2: String, Codable, CaseIterable, Sendable {
  case pending
  case accepted
  case rejected
}

public struct MatchCandidateV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let idempotencyKey: String
  public let importCandidateID: UUID
  public let evidenceID: UUID
  public var journalCandidateID: UUID?
  public let confidenceBasisPoints: Int
  public let explanation: String
  public var state: MatchCandidateStateV2
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    idempotencyKey: String,
    importCandidateID: UUID,
    evidenceID: UUID,
    journalCandidateID: UUID? = nil,
    confidenceBasisPoints: Int,
    explanation: String,
    state: MatchCandidateStateV2 = .pending,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.importCandidateID = importCandidateID
    self.evidenceID = evidenceID
    self.journalCandidateID = journalCandidateID
    self.confidenceBasisPoints = min(max(confidenceBasisPoints, 0), 10_000)
    self.explanation = explanation
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ExportSnapshotV1: Codable, Equatable, Sendable {
  public let formatFamily: String
  public let version: Int
  public let generatedAt: Date
  public let fiscalYear: Int
  public let journalEntryCount: Int
  public let evidenceCount: Int
  public let debitTotalYen: Int64
  public let creditTotalYen: Int64
  public let contentSHA256: String

  public init(
    formatFamily: String = "blueprint-export",
    version: Int = 1,
    generatedAt: Date,
    fiscalYear: Int,
    journalEntryCount: Int,
    evidenceCount: Int,
    debitTotalYen: Int64,
    creditTotalYen: Int64,
    contentSHA256: String
  ) {
    self.formatFamily = formatFamily
    self.version = version
    self.generatedAt = generatedAt
    self.fiscalYear = fiscalYear
    self.journalEntryCount = journalEntryCount
    self.evidenceCount = evidenceCount
    self.debitTotalYen = debitTotalYen
    self.creditTotalYen = creditTotalYen
    self.contentSHA256 = contentSHA256
  }
}

public struct CaptureEnvelopeV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let protocolVersion: Int
  public let idempotencyKey: String
  public let capturedAt: Date
  public let originalFilename: String
  public let mediaType: String
  public let byteCount: Int64
  public let sha256: String

  public init(
    id: UUID = UUID(),
    protocolVersion: Int = 2,
    idempotencyKey: String,
    capturedAt: Date,
    originalFilename: String,
    mediaType: String,
    byteCount: Int64,
    sha256: String
  ) {
    self.id = id
    self.protocolVersion = protocolVersion
    self.idempotencyKey = idempotencyKey
    self.capturedAt = capturedAt
    self.originalFilename = originalFilename
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct JournalTemplateV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var defaultDescription: String
  public var debitAccountID: UUID
  public var creditAccountID: UUID
  public var taxRate: TaxRate
  public var invoiceStatus: InvoiceRegistrationStatus
  public var isActive: Bool
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    defaultDescription: String,
    debitAccountID: UUID,
    creditAccountID: UUID,
    taxRate: TaxRate,
    invoiceStatus: InvoiceRegistrationStatus,
    isActive: Bool = true,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.defaultDescription = defaultDescription
    self.debitAccountID = debitAccountID
    self.creditAccountID = creditAccountID
    self.taxRate = taxRate
    self.invoiceStatus = invoiceStatus
    self.isActive = isActive
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct JournalRuleV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var descriptionContains: String
  public var debitAccountID: UUID
  public var creditAccountID: UUID
  public var taxRate: TaxRate
  public var priority: Int
  public var isActive: Bool
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    descriptionContains: String,
    debitAccountID: UUID,
    creditAccountID: UUID,
    taxRate: TaxRate,
    priority: Int = 100,
    isActive: Bool = true,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.descriptionContains = descriptionContains
    self.debitAccountID = debitAccountID
    self.creditAccountID = creditAccountID
    self.taxRate = taxRate
    self.priority = priority
    self.isActive = isActive
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum RecurrenceFrequencyV2: String, Codable, CaseIterable, Sendable {
  case monthly
  case yearly
}

public struct RecurringJournalV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let templateID: UUID
  public var frequency: RecurrenceFrequencyV2
  public var dayOfMonth: Int
  public var amountYen: Int64
  public var nextRunAt: Date
  public var isActive: Bool
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    templateID: UUID,
    frequency: RecurrenceFrequencyV2,
    dayOfMonth: Int,
    amountYen: Int64,
    nextRunAt: Date,
    isActive: Bool = true,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.templateID = templateID
    self.frequency = frequency
    self.dayOfMonth = min(max(dayOfMonth, 1), 28)
    self.amountYen = max(amountYen, 1)
    self.nextRunAt = nextRunAt
    self.isActive = isActive
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum JournalCandidateStateV2: String, Codable, CaseIterable, Sendable {
  case pending
  case confirmed
  case rejected
}

public struct JournalCandidateV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let idempotencyKey: String
  public let sourceKind: String
  public let sourceID: UUID?
  public var transactionDate: Date
  public var description: String
  public var amountYen: Int64
  public var debitAccountID: UUID
  public var creditAccountID: UUID
  public var taxRate: TaxRate
  public var invoiceStatus: InvoiceRegistrationStatus
  public var confidenceBasisPoints: Int
  public var explanation: String
  public var state: JournalCandidateStateV2
  public var journalEntryID: UUID?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    idempotencyKey: String,
    sourceKind: String,
    sourceID: UUID? = nil,
    transactionDate: Date,
    description: String,
    amountYen: Int64,
    debitAccountID: UUID,
    creditAccountID: UUID,
    taxRate: TaxRate,
    invoiceStatus: InvoiceRegistrationStatus = .unknown,
    confidenceBasisPoints: Int,
    explanation: String,
    state: JournalCandidateStateV2 = .pending,
    journalEntryID: UUID? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.sourceKind = sourceKind
    self.sourceID = sourceID
    self.transactionDate = transactionDate
    self.description = description
    self.amountYen = max(amountYen, 1)
    self.debitAccountID = debitAccountID
    self.creditAccountID = creditAccountID
    self.taxRate = taxRate
    self.invoiceStatus = invoiceStatus
    self.confidenceBasisPoints = min(max(confidenceBasisPoints, 0), 10_000)
    self.explanation = explanation
    self.state = state
    self.journalEntryID = journalEntryID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ClosingDecisionStateV2: String, Codable, CaseIterable, Sendable {
  case pending
  case confirmed
  case notApplicable
}

public struct ClosingDecisionV2: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let fiscalYearID: UUID
  public var decisionType: String
  public var state: ClosingDecisionStateV2
  public var amountYen: Int64?
  public var rationale: String
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    fiscalYearID: UUID,
    decisionType: String,
    state: ClosingDecisionStateV2 = .pending,
    amountYen: Int64? = nil,
    rationale: String,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.decisionType = decisionType
    self.state = state
    self.amountYen = amountYen
    self.rationale = rationale
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
