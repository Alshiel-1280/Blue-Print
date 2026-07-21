import BlueprintDocuments
import BlueprintDomain
import Foundation

public enum ImportedTransactionState: String, Codable, CaseIterable, Sendable {
  case unprocessed
  case needsReview
  case posted
  case excluded
}

public enum ImportBatchState: String, Codable, CaseIterable, Sendable {
  case preview
  case imported
  case partiallyFailed
  case cancelled
}

public enum ImportSourceKind: String, Codable, CaseIterable, Sendable {
  case bankCSV
  case cardCSV
  case manualCSV
}

public enum CSVEncoding: String, Codable, CaseIterable, Sendable {
  case utf8
  case shiftJIS
}

public enum CSVDelimiter: String, Codable, CaseIterable, Sendable {
  case comma = ","
  case tab = "\t"
  case semicolon = ";"
}

public struct ImportColumnMapping: Codable, Equatable, Sendable {
  public var dateColumn: Int
  public var amountColumn: Int
  public var descriptionColumn: Int
  public var externalIDColumn: Int?
  public var balanceColumn: Int?
  public var dateFormat: String

  public init(
    dateColumn: Int,
    amountColumn: Int,
    descriptionColumn: Int,
    externalIDColumn: Int? = nil,
    balanceColumn: Int? = nil,
    dateFormat: String = "yyyy/MM/dd"
  ) {
    self.dateColumn = dateColumn
    self.amountColumn = amountColumn
    self.descriptionColumn = descriptionColumn
    self.externalIDColumn = externalIDColumn
    self.balanceColumn = balanceColumn
    self.dateFormat = dateFormat
  }
}

public struct ImportProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var name: String
  public var sourceKind: ImportSourceKind
  public var encoding: CSVEncoding
  public var delimiter: CSVDelimiter
  public var hasHeader: Bool
  public var mapping: ImportColumnMapping
  public var updatedAt: Date

  public init(
    id: EntityID = UUID(),
    name: String,
    sourceKind: ImportSourceKind,
    encoding: CSVEncoding,
    delimiter: CSVDelimiter,
    hasHeader: Bool,
    mapping: ImportColumnMapping,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.sourceKind = sourceKind
    self.encoding = encoding
    self.delimiter = delimiter
    self.hasHeader = hasHeader
    self.mapping = mapping
    self.updatedAt = updatedAt
  }
}

public struct ImportedTransaction: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let batchID: EntityID
  public let rowNumber: Int
  public var transactionDate: Date
  public var amount: Money
  public var description: String
  public var externalID: String?
  public var runningBalance: Money?
  public var state: ImportedTransactionState
  public var evidenceID: EntityID?
  public var journalEntryID: EntityID?
  public var duplicateOfID: EntityID?

  public init(
    id: EntityID = UUID(),
    batchID: EntityID,
    rowNumber: Int,
    transactionDate: Date,
    amount: Money,
    description: String,
    externalID: String? = nil,
    runningBalance: Money? = nil,
    state: ImportedTransactionState = .unprocessed,
    evidenceID: EntityID? = nil,
    journalEntryID: EntityID? = nil,
    duplicateOfID: EntityID? = nil
  ) {
    self.id = id
    self.batchID = batchID
    self.rowNumber = rowNumber
    self.transactionDate = transactionDate
    self.amount = amount
    self.description = description
    self.externalID = externalID
    self.runningBalance = runningBalance
    self.state = state
    self.evidenceID = evidenceID
    self.journalEntryID = journalEntryID
    self.duplicateOfID = duplicateOfID
  }

  public var duplicateKey: String {
    let day = Int(transactionDate.timeIntervalSince1970 / 86_400)
    return "\(externalID ?? "")|\(day)|\(amount.yen)|\(description.normalizedForImport)"
  }
}

public struct ImportRowError: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let batchID: EntityID
  public let rowNumber: Int
  public let rawRow: String
  public let message: String

  public init(
    id: EntityID = UUID(),
    batchID: EntityID,
    rowNumber: Int,
    rawRow: String,
    message: String
  ) {
    self.id = id
    self.batchID = batchID
    self.rowNumber = rowNumber
    self.rawRow = rawRow
    self.message = message
  }
}

public struct ImportBatch: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let profileID: EntityID?
  public let sourceFilename: String
  public let importedAt: Date
  public var state: ImportBatchState
  public var transactions: [ImportedTransaction]
  public var errors: [ImportRowError]

  public init(
    id: EntityID = UUID(),
    profileID: EntityID?,
    sourceFilename: String,
    importedAt: Date,
    state: ImportBatchState,
    transactions: [ImportedTransaction],
    errors: [ImportRowError]
  ) {
    self.id = id
    self.profileID = profileID
    self.sourceFilename = sourceFilename
    self.importedAt = importedAt
    self.state = state
    self.transactions = transactions
    self.errors = errors
  }

  public mutating func cancelUnposted() {
    guard transactions.allSatisfy({ $0.state != .posted }) else { return }
    state = .cancelled
    for index in transactions.indices { transactions[index].state = .excluded }
  }
}

public struct BankReconciliation: Equatable, Sendable {
  public let statementBalance: Money
  public let bookBalance: Money
  public var difference: Money { Money(yen: statementBalance.yen - bookBalance.yen) }
  public var isReconciled: Bool { difference == .zero }

  public init(statementBalance: Money, bookBalance: Money) {
    self.statementBalance = statementBalance
    self.bookBalance = bookBalance
  }
}

public struct TransactionEvidenceCandidate: Equatable, Identifiable, Sendable {
  public let evidenceID: EntityID
  public let score: Double
  public let reasons: [String]

  public var id: EntityID { evidenceID }

  public init(evidenceID: EntityID, score: Double, reasons: [String]) {
    self.evidenceID = evidenceID
    self.score = min(max(score, 0), 1)
    self.reasons = reasons
  }
}

public protocol ImportRepository: Sendable {
  func saveProfile(_ profile: ImportProfile) throws
  func profiles() throws -> [ImportProfile]
  func saveBatch(_ batch: ImportBatch) throws
  func batches() throws -> [ImportBatch]
  func transactions(states: Set<ImportedTransactionState>) throws -> [ImportedTransaction]
  func cancelBatch(id: EntityID) throws
  func updateTransaction(_ transaction: ImportedTransaction) throws
}

extension String {
  fileprivate var normalizedForImport: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "　", with: "")
  }
}
