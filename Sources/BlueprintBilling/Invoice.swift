import BlueprintDomain
import Foundation

public enum BillingError: Error, Equatable, Sendable {
  case emptyLines
  case invalidAmount
  case invalidStateTransition
  case duplicateNumber
  case missingQualifiedInvoiceField(String)
  case settlementExceedsOutstanding
  case settlementComponentsDoNotBalance
  case alreadyPosted
  case missingReason
}

public enum InvoiceKind: String, Codable, CaseIterable, Sendable {
  case standard
  case correction
  case refund
}

public struct InvoiceLine: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var description: String
  public var quantity: Int64
  public var unitPrice: Money
  public var taxRate: TaxRate

  public init(
    id: EntityID = UUID(),
    description: String,
    quantity: Int64,
    unitPrice: Money,
    taxRate: TaxRate
  ) throws {
    guard quantity > 0, unitPrice.yen >= 0 else { throw BillingError.invalidAmount }
    self.id = id
    self.description = description
    self.quantity = quantity
    self.unitPrice = unitPrice
    self.taxRate = taxRate
  }

  public func netAmount() throws -> Money { try unitPrice.multiplied(by: quantity) }
}

public struct InvoiceTaxSummary: Codable, Equatable, Sendable, Identifiable {
  public let taxRate: TaxRate
  public let netAmount: Money
  public let taxAmount: Money

  public var id: String { taxRate.rawValue }
  public var grossAmount: Money { Money(yen: netAmount.yen + taxAmount.yen) }
}

public struct InvoiceSettlement: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let receivedAt: Date
  public let appliedAmount: Money
  public let cashReceived: Money
  public let bankFee: Money
  public let withholdingTax: Money
  public let discount: Money
  public let overpayment: Money
  public let sourceTransactionID: EntityID?
  public let journalEntryID: EntityID?

  public init(
    id: EntityID = UUID(),
    receivedAt: Date,
    appliedAmount: Money,
    cashReceived: Money,
    bankFee: Money = .zero,
    withholdingTax: Money = .zero,
    discount: Money = .zero,
    overpayment: Money = .zero,
    sourceTransactionID: EntityID? = nil,
    journalEntryID: EntityID? = nil
  ) throws {
    let values = [appliedAmount, cashReceived, bankFee, withholdingTax, discount, overpayment]
    guard values.allSatisfy({ $0.yen >= 0 }), appliedAmount.yen > 0 else {
      throw BillingError.invalidAmount
    }
    guard
      cashReceived.yen + bankFee.yen + withholdingTax.yen + discount.yen
        == appliedAmount.yen + overpayment.yen
    else { throw BillingError.settlementComponentsDoNotBalance }
    self.id = id
    self.receivedAt = receivedAt
    self.appliedAmount = appliedAmount
    self.cashReceived = cashReceived
    self.bankFee = bankFee
    self.withholdingTax = withholdingTax
    self.discount = discount
    self.overpayment = overpayment
    self.sourceTransactionID = sourceTransactionID
    self.journalEntryID = journalEntryID
  }
}

public struct InvoiceReissue: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let invoiceID: EntityID
  public let sequence: Int
  public let issuedAt: Date
  public let reason: String
  public let evidenceID: EntityID

  public init(
    id: EntityID = UUID(),
    invoiceID: EntityID,
    sequence: Int,
    issuedAt: Date,
    reason: String,
    evidenceID: EntityID
  ) {
    self.id = id
    self.invoiceID = invoiceID
    self.sequence = sequence
    self.issuedAt = issuedAt
    self.reason = reason
    self.evidenceID = evidenceID
  }
}

public struct Invoice: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let fiscalYearID: EntityID
  public let counterpartyID: EntityID
  public var number: String
  public var issueDate: Date
  public var dueDate: Date
  public var subject: String
  public var kind: InvoiceKind
  public var status: InvoiceStatus
  public var lines: [InvoiceLine]
  public var roundingRule: RoundingRule
  public var issuerName: String
  public var issuerAddress: String
  public var issuerRegistrationStatus: InvoiceRegistrationStatus
  public var issuerRegistrationNumber: String?
  public var sourceInvoiceID: EntityID?
  public var reason: String?
  public var journalEntryID: EntityID?
  public var evidenceID: EntityID?
  public var settlements: [InvoiceSettlement]

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    counterpartyID: EntityID,
    number: String,
    issueDate: Date,
    dueDate: Date,
    subject: String,
    kind: InvoiceKind = .standard,
    status: InvoiceStatus = .draft,
    lines: [InvoiceLine],
    roundingRule: RoundingRule = .down,
    issuerName: String,
    issuerAddress: String = "",
    issuerRegistrationStatus: InvoiceRegistrationStatus,
    issuerRegistrationNumber: String? = nil,
    sourceInvoiceID: EntityID? = nil,
    reason: String? = nil,
    journalEntryID: EntityID? = nil,
    evidenceID: EntityID? = nil,
    settlements: [InvoiceSettlement] = []
  ) throws {
    guard !lines.isEmpty else { throw BillingError.emptyLines }
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.counterpartyID = counterpartyID
    self.number = number
    self.issueDate = issueDate
    self.dueDate = dueDate
    self.subject = subject
    self.kind = kind
    self.status = status
    self.lines = lines
    self.roundingRule = roundingRule
    self.issuerName = issuerName
    self.issuerAddress = issuerAddress
    self.issuerRegistrationStatus = issuerRegistrationStatus
    self.issuerRegistrationNumber = issuerRegistrationNumber
    self.sourceInvoiceID = sourceInvoiceID
    self.reason = reason
    self.journalEntryID = journalEntryID
    self.evidenceID = evidenceID
    self.settlements = settlements
  }

  public func taxSummaries() throws -> [InvoiceTaxSummary] {
    var result: [InvoiceTaxSummary] = []
    for rate in TaxRate.allCases {
      let net = try lines.filter { $0.taxRate == rate }.reduce(Money.zero) {
        try $0.adding($1.netAmount())
      }
      guard net != .zero else { continue }
      let tax =
        rate.basisPoints.map {
          Money(yen: roundingRule.apply(Decimal(net.yen) * Decimal($0) / Decimal(10_000)))
        } ?? .zero
      result.append(InvoiceTaxSummary(taxRate: rate, netAmount: net, taxAmount: tax))
    }
    return result
  }

  public func total() throws -> Money {
    try taxSummaries().reduce(Money.zero) { try $0.adding($1.grossAmount) }
  }

  public var paidAmount: Money {
    Money(yen: settlements.reduce(0) { $0 + $1.appliedAmount.yen })
  }

  public func outstandingAmount() throws -> Money { try total().subtracting(paidAmount) }

  public func validateForIssue() throws {
    guard status == .draft else { throw BillingError.invalidStateTransition }
    try validateDocumentFields()
  }

  public func validateDocumentFields() throws {
    guard !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BillingError.missingQualifiedInvoiceField("請求番号")
    }
    guard !issuerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BillingError.missingQualifiedInvoiceField("発行者名")
    }
    if issuerRegistrationStatus == .qualified {
      guard let number = issuerRegistrationNumber, Self.validRegistrationNumber(number) else {
        throw BillingError.missingQualifiedInvoiceField("登録番号")
      }
      guard !issuerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BillingError.missingQualifiedInvoiceField("発行者住所")
      }
    }
    guard try total().yen > 0 else { throw BillingError.invalidAmount }
  }

  public mutating func markIssued(journalEntryID: EntityID, evidenceID: EntityID, at date: Date)
    throws
  {
    try validateForIssue()
    status = .issued
    self.journalEntryID = journalEntryID
    self.evidenceID = evidenceID
    metadata.touch(at: date)
  }

  public mutating func applySettlement(_ settlement: InvoiceSettlement, at date: Date) throws {
    guard status == .issued || status == .partiallyPaid || status == .overdue else {
      throw BillingError.invalidStateTransition
    }
    guard settlement.appliedAmount <= (try outstandingAmount()) else {
      throw BillingError.settlementExceedsOutstanding
    }
    settlements.append(settlement)
    status = try outstandingAmount() == .zero ? .paid : .partiallyPaid
    metadata.touch(at: date)
  }

  public mutating func cancel(reason: String, at date: Date) throws {
    guard status == .issued || status == .overdue, settlements.isEmpty else {
      throw BillingError.invalidStateTransition
    }
    let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw BillingError.missingReason }
    status = .cancelled
    self.reason = normalized
    metadata.touch(at: date)
  }

  public func correction(
    metadata: EntityMetadata,
    number: String,
    lines: [InvoiceLine],
    reason: String
  ) throws -> Invoice {
    let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw BillingError.missingReason }
    return try Invoice(
      metadata: metadata,
      fiscalYearID: fiscalYearID,
      counterpartyID: counterpartyID,
      number: number,
      issueDate: issueDate,
      dueDate: dueDate,
      subject: subject,
      kind: .correction,
      lines: lines,
      roundingRule: roundingRule,
      issuerName: issuerName,
      issuerAddress: issuerAddress,
      issuerRegistrationStatus: issuerRegistrationStatus,
      issuerRegistrationNumber: issuerRegistrationNumber,
      sourceInvoiceID: id,
      reason: normalized
    )
  }

  private static func validRegistrationNumber(_ value: String) -> Bool {
    value.range(of: #"^T\d{13}$"#, options: .regularExpression) != nil
  }
}

public enum InvoiceNumbering {
  public static func next(calendarYear: Int, existingNumbers: [String]) -> String {
    let prefix = "INV-\(calendarYear)-"
    let highest =
      existingNumbers.compactMap { value -> Int? in
        guard value.hasPrefix(prefix) else { return nil }
        return Int(value.dropFirst(prefix.count))
      }.max() ?? 0
    return prefix + String(format: "%04d", highest + 1)
  }
}
