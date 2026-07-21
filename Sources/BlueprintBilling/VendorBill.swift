import BlueprintDomain
import Foundation

public enum VendorBillStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case confirmed
  case partiallyPaid
  case paid
  case cancelled
}

public struct VendorBillPayment: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let paidAt: Date
  public let appliedAmount: Money
  public let cashPaid: Money
  public let withholdingTax: Money
  public let bankFee: Money
  public let sourceTransactionID: EntityID?
  public let journalEntryID: EntityID?

  public init(
    id: EntityID = UUID(),
    paidAt: Date,
    appliedAmount: Money,
    cashPaid: Money,
    withholdingTax: Money = .zero,
    bankFee: Money = .zero,
    sourceTransactionID: EntityID? = nil,
    journalEntryID: EntityID? = nil
  ) throws {
    guard appliedAmount.yen > 0, cashPaid.yen >= 0, withholdingTax.yen >= 0, bankFee.yen >= 0
    else { throw BillingError.invalidAmount }
    guard cashPaid.yen + withholdingTax.yen == appliedAmount.yen else {
      throw BillingError.settlementComponentsDoNotBalance
    }
    self.id = id
    self.paidAt = paidAt
    self.appliedAmount = appliedAmount
    self.cashPaid = cashPaid
    self.withholdingTax = withholdingTax
    self.bankFee = bankFee
    self.sourceTransactionID = sourceTransactionID
    self.journalEntryID = journalEntryID
  }
}

public struct VendorBill: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let fiscalYearID: EntityID
  public let vendorID: EntityID
  public var referenceNumber: String
  public var issueDate: Date
  public var dueDate: Date
  public var description: String
  public var lines: [InvoiceLine]
  public var invoiceStatus: InvoiceRegistrationStatus
  public var withholdingEnabled: Bool
  public var withholdingTax: Money
  public var status: VendorBillStatus
  public var journalEntryID: EntityID?
  public var evidenceID: EntityID?
  public var payments: [VendorBillPayment]

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    vendorID: EntityID,
    referenceNumber: String,
    issueDate: Date,
    dueDate: Date,
    description: String,
    lines: [InvoiceLine],
    invoiceStatus: InvoiceRegistrationStatus,
    withholdingEnabled: Bool = false,
    withholdingTax: Money = .zero,
    status: VendorBillStatus = .draft,
    journalEntryID: EntityID? = nil,
    evidenceID: EntityID? = nil,
    payments: [VendorBillPayment] = []
  ) throws {
    guard !lines.isEmpty else { throw BillingError.emptyLines }
    guard withholdingTax.yen >= 0 else { throw BillingError.invalidAmount }
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.vendorID = vendorID
    self.referenceNumber = referenceNumber
    self.issueDate = issueDate
    self.dueDate = dueDate
    self.description = description
    self.lines = lines
    self.invoiceStatus = invoiceStatus
    self.withholdingEnabled = withholdingEnabled
    self.withholdingTax = withholdingEnabled ? withholdingTax : .zero
    self.status = status
    self.journalEntryID = journalEntryID
    self.evidenceID = evidenceID
    self.payments = payments
  }

  public func grossAmount(roundingRule: RoundingRule = .down) throws -> Money {
    try invoiceForCalculations(roundingRule: roundingRule).total()
  }

  public func taxSummaries(roundingRule: RoundingRule = .down) throws -> [InvoiceTaxSummary] {
    try invoiceForCalculations(roundingRule: roundingRule).taxSummaries()
  }

  private func invoiceForCalculations(roundingRule: RoundingRule) throws -> Invoice {
    try Invoice(
      metadata: metadata,
      fiscalYearID: fiscalYearID,
      counterpartyID: vendorID,
      number: referenceNumber,
      issueDate: issueDate,
      dueDate: dueDate,
      subject: description,
      lines: lines,
      roundingRule: roundingRule,
      issuerName: "vendor",
      issuerRegistrationStatus: invoiceStatus
    )
  }

  public func netPayable(roundingRule: RoundingRule = .down) throws -> Money {
    try grossAmount(roundingRule: roundingRule).subtracting(withholdingTax)
  }

  public var paidAmount: Money {
    Money(yen: payments.reduce(0) { $0 + $1.appliedAmount.yen })
  }

  public func outstandingAmount() throws -> Money { try grossAmount().subtracting(paidAmount) }

  public mutating func confirm(journalEntryID: EntityID, at date: Date) throws {
    guard status == .draft else { throw BillingError.invalidStateTransition }
    status = .confirmed
    self.journalEntryID = journalEntryID
    metadata.touch(at: date)
  }

  public mutating func applyPayment(_ payment: VendorBillPayment, at date: Date) throws {
    guard status == .confirmed || status == .partiallyPaid else {
      throw BillingError.invalidStateTransition
    }
    guard payment.appliedAmount <= (try outstandingAmount()) else {
      throw BillingError.settlementExceedsOutstanding
    }
    payments.append(payment)
    status = try outstandingAmount() == .zero ? .paid : .partiallyPaid
    metadata.touch(at: date)
  }
}
