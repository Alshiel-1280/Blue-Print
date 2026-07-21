import BlueprintDomain
import Foundation

public struct BillingSearch: Equatable, Sendable {
  public var fiscalYearID: EntityID?
  public var counterpartyID: EntityID?
  public var invoiceStatuses: Set<InvoiceStatus>
  public var vendorBillStatuses: Set<VendorBillStatus>
  public var overdueAsOf: Date?

  public init(
    fiscalYearID: EntityID? = nil,
    counterpartyID: EntityID? = nil,
    invoiceStatuses: Set<InvoiceStatus> = Set(InvoiceStatus.allCases),
    vendorBillStatuses: Set<VendorBillStatus> = Set(VendorBillStatus.allCases),
    overdueAsOf: Date? = nil
  ) {
    self.fiscalYearID = fiscalYearID
    self.counterpartyID = counterpartyID
    self.invoiceStatuses = invoiceStatuses
    self.vendorBillStatuses = vendorBillStatuses
    self.overdueAsOf = overdueAsOf
  }
}

public protocol BillingRepository: Sendable {
  func saveCounterparty(_ counterparty: Counterparty) throws
  func counterparties(includeInactive: Bool) throws -> [Counterparty]
  func saveInvoice(_ invoice: Invoice) throws
  func invoice(id: EntityID) throws -> Invoice?
  func invoice(number: String) throws -> Invoice?
  func invoices(_ search: BillingSearch) throws -> [Invoice]
  func appendReissue(_ reissue: InvoiceReissue) throws
  func reissues(invoiceID: EntityID) throws -> [InvoiceReissue]
  func saveVendorBill(_ bill: VendorBill) throws
  func vendorBill(id: EntityID) throws -> VendorBill?
  func vendorBills(_ search: BillingSearch) throws -> [VendorBill]
}
