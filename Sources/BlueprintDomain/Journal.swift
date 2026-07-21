import Foundation

public enum PostingSide: String, Codable, CaseIterable, Sendable {
  case debit
  case credit

  public var opposite: PostingSide { self == .debit ? .credit : .debit }
}

public enum JournalEntryStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case pendingReview
  case posted
  case reversed
  case corrected

  public var countsInLedger: Bool {
    self == .posted || self == .reversed || self == .corrected
  }
}

public enum JournalEntryKind: String, Codable, CaseIterable, Sendable {
  case standard
  case opening
  case closing
  case reversal
  case correction
}

public enum JournalError: Error, Equatable, Sendable {
  case amountMustBePositive
  case requiresAtLeastTwoLines
  case debitsAndCreditsDoNotMatch(debits: Int64, credits: Int64)
  case dateOutsideFiscalYear
  case cannotModifyPostedEntry
  case invalidStateTransition
  case missingReason
}

public struct JournalLine: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: EntityID
  public var accountID: EntityID
  public var subAccountID: EntityID?
  public var side: PostingSide
  public var amount: Money
  public var taxRate: TaxRate
  public var invoiceStatus: InvoiceRegistrationStatus
  public var deductibleBasisPoints: Int
  public var roundingUnit: RoundingUnit
  public var counterparty: String
  public var memo: String

  public init(
    id: EntityID = UUID(),
    accountID: EntityID,
    subAccountID: EntityID? = nil,
    side: PostingSide,
    amount: Money,
    taxRate: TaxRate = .outOfScope,
    invoiceStatus: InvoiceRegistrationStatus = .unknown,
    deductibleBasisPoints: Int = 10_000,
    roundingUnit: RoundingUnit = .line,
    counterparty: String = "",
    memo: String = ""
  ) throws {
    guard amount.yen > 0 else { throw JournalError.amountMustBePositive }
    guard (0...10_000).contains(deductibleBasisPoints) else {
      throw JournalError.invalidStateTransition
    }
    self.id = id
    self.accountID = accountID
    self.subAccountID = subAccountID
    self.side = side
    self.amount = amount
    self.taxRate = taxRate
    self.invoiceStatus = invoiceStatus
    self.deductibleBasisPoints = deductibleBasisPoints
    self.roundingUnit = roundingUnit
    self.counterparty = counterparty
    self.memo = memo
  }

  public func reversed() throws -> JournalLine {
    try JournalLine(
      accountID: accountID,
      subAccountID: subAccountID,
      side: side.opposite,
      amount: amount,
      taxRate: taxRate,
      invoiceStatus: invoiceStatus,
      deductibleBasisPoints: deductibleBasisPoints,
      roundingUnit: roundingUnit,
      counterparty: counterparty,
      memo: memo
    )
  }
}

public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let fiscalYearID: EntityID
  public var transactionDate: Date
  public var description: String
  public var kind: JournalEntryKind
  public var status: JournalEntryStatus
  public var lines: [JournalLine]
  public var sourceEntryID: EntityID?
  public var reason: String?
  public var postedAt: Date?

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    transactionDate: Date,
    description: String,
    kind: JournalEntryKind = .standard,
    status: JournalEntryStatus = .draft,
    lines: [JournalLine],
    sourceEntryID: EntityID? = nil,
    reason: String? = nil,
    postedAt: Date? = nil
  ) {
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.transactionDate = transactionDate
    self.description = description
    self.kind = kind
    self.status = status
    self.lines = lines
    self.sourceEntryID = sourceEntryID
    self.reason = reason
    self.postedAt = postedAt
  }

  public func totals() throws -> (debits: Money, credits: Money) {
    var debit = Money.zero
    var credit = Money.zero
    for line in lines {
      switch line.side {
      case .debit: debit = try debit.adding(line.amount)
      case .credit: credit = try credit.adding(line.amount)
      }
    }
    return (debit, credit)
  }

  public func validate(for fiscalYear: FiscalYear) throws {
    guard lines.count >= 2 else { throw JournalError.requiresAtLeastTwoLines }
    let totals = try totals()
    guard totals.debits == totals.credits else {
      throw JournalError.debitsAndCreditsDoNotMatch(
        debits: totals.debits.yen,
        credits: totals.credits.yen
      )
    }
    let calendar = Calendar(identifier: .gregorian)
    guard calendar.component(.year, from: transactionDate) == fiscalYear.calendarYear else {
      throw JournalError.dateOutsideFiscalYear
    }
  }

  public mutating func markPendingReview(at date: Date) throws {
    guard status == .draft else { throw JournalError.invalidStateTransition }
    status = .pendingReview
    metadata.touch(at: date)
  }

  public mutating func post(for fiscalYear: FiscalYear, at date: Date) throws {
    guard status == .draft || status == .pendingReview else {
      throw JournalError.invalidStateTransition
    }
    guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
    try validate(for: fiscalYear)
    status = .posted
    postedAt = date
    metadata.touch(at: date)
  }

  public func makeReversal(at date: Date, reason: String) throws -> JournalEntry {
    guard status == .posted else { throw JournalError.invalidStateTransition }
    let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedReason.isEmpty else { throw JournalError.missingReason }
    return JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: date,
      description: "取消: \(description)",
      kind: .reversal,
      status: .draft,
      lines: try lines.map { try $0.reversed() },
      sourceEntryID: id,
      reason: normalizedReason
    )
  }

  public func makeCorrection(
    metadata: EntityMetadata,
    transactionDate: Date,
    description: String,
    lines: [JournalLine],
    reason: String
  ) throws -> JournalEntry {
    guard status == .posted else { throw JournalError.invalidStateTransition }
    let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedReason.isEmpty else { throw JournalError.missingReason }
    return JournalEntry(
      metadata: metadata,
      fiscalYearID: fiscalYearID,
      transactionDate: transactionDate,
      description: description,
      kind: .correction,
      status: .draft,
      lines: lines,
      sourceEntryID: id,
      reason: normalizedReason
    )
  }

  public static func openingBalance(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    transactionDate: Date,
    balances: [(accountID: EntityID, signedDebitBalance: Money)],
    capitalAccountID: EntityID
  ) throws -> JournalEntry {
    var lines: [JournalLine] = []
    var netDebit = Money.zero
    for balance in balances where balance.signedDebitBalance != .zero {
      let isDebit = balance.signedDebitBalance.yen > 0
      let amount = try magnitude(balance.signedDebitBalance.yen)
      lines.append(
        try JournalLine(
          accountID: balance.accountID,
          side: isDebit ? .debit : .credit,
          amount: amount
        ))
      netDebit = isDebit ? try netDebit.adding(amount) : try netDebit.subtracting(amount)
    }
    guard netDebit != .zero else { throw JournalError.invalidStateTransition }
    lines.append(
      try JournalLine(
        accountID: capitalAccountID,
        side: netDebit.yen > 0 ? .credit : .debit,
        amount: try magnitude(netDebit.yen)
      ))
    return JournalEntry(
      metadata: metadata,
      fiscalYearID: fiscalYearID,
      transactionDate: transactionDate,
      description: "期首残高",
      kind: .opening,
      lines: lines
    )
  }

  public static func ownerEquityClosing(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    transactionDate: Date,
    ownerDrawingsAccountID: EntityID,
    ownerDrawings: Money,
    ownerContributionsAccountID: EntityID,
    ownerContributions: Money,
    capitalAccountID: EntityID
  ) throws -> JournalEntry {
    guard ownerDrawings.yen >= 0, ownerContributions.yen >= 0 else {
      throw JournalError.amountMustBePositive
    }
    var lines: [JournalLine] = []
    if ownerDrawings.yen > 0 {
      lines.append(
        try JournalLine(
          accountID: capitalAccountID,
          side: .debit,
          amount: ownerDrawings
        ))
      lines.append(
        try JournalLine(
          accountID: ownerDrawingsAccountID,
          side: .credit,
          amount: ownerDrawings
        ))
    }
    if ownerContributions.yen > 0 {
      lines.append(
        try JournalLine(
          accountID: ownerContributionsAccountID,
          side: .debit,
          amount: ownerContributions
        ))
      lines.append(
        try JournalLine(
          accountID: capitalAccountID,
          side: .credit,
          amount: ownerContributions
        ))
    }
    guard lines.count >= 2 else { throw JournalError.requiresAtLeastTwoLines }
    return JournalEntry(
      metadata: metadata,
      fiscalYearID: fiscalYearID,
      transactionDate: transactionDate,
      description: "事業主勘定の年次振替",
      kind: .closing,
      lines: lines
    )
  }

  private static func magnitude(_ value: Int64) throws -> Money {
    guard value != Int64.min else { throw MoneyError.overflow }
    return Money(yen: abs(value))
  }
}

public struct JournalSearch: Equatable, Sendable {
  public var fiscalYearID: EntityID
  public var dateRange: ClosedRange<Date>?
  public var accountID: EntityID?
  public var minimumAmount: Money?
  public var maximumAmount: Money?
  public var text: String?
  public var statuses: Set<JournalEntryStatus>

  public init(
    fiscalYearID: EntityID,
    dateRange: ClosedRange<Date>? = nil,
    accountID: EntityID? = nil,
    minimumAmount: Money? = nil,
    maximumAmount: Money? = nil,
    text: String? = nil,
    statuses: Set<JournalEntryStatus> = Set(JournalEntryStatus.allCases)
  ) {
    self.fiscalYearID = fiscalYearID
    self.dateRange = dateRange
    self.accountID = accountID
    self.minimumAmount = minimumAmount
    self.maximumAmount = maximumAmount
    self.text = text
    self.statuses = statuses
  }
}
