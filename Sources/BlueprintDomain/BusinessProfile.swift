import Foundation

public enum BookkeepingStyle: String, Codable, CaseIterable, Sendable {
  case doubleEntry
  case simple
}

public enum ConsumptionTaxStatus: String, Codable, CaseIterable, Sendable {
  case exempt
  case generalTaxation
  case simplifiedTaxation
  case annualSpecialRule
}

public enum TaxAccountingMethod: String, Codable, CaseIterable, Sendable {
  case taxInclusive
  case taxExclusive
}

public struct BusinessProfile: Codable, Equatable, Sendable, Identifiable {
  public var metadata: EntityMetadata
  public var fiscalYearID: EntityID
  public var ownerName: String
  public var tradeName: String
  public var postalAddress: String
  public var taxAddress: String
  public var taxOffice: String
  public var industry: String
  public var openedOn: Date?
  public var blueReturnApproved: Bool
  public var bookkeepingStyle: BookkeepingStyle
  public var consumptionTaxStatus: ConsumptionTaxStatus
  public var invoiceRegistrationStatus: InvoiceRegistrationStatus
  public var invoiceRegistrationNumber: String?
  public var invoiceRegisteredOn: Date?
  public var invoiceCancelledOn: Date?
  public var taxAccountingMethod: TaxAccountingMethod
  public var roundingRule: RoundingRule
  public var defaultTaxRate: TaxRate

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    ownerName: String,
    tradeName: String,
    postalAddress: String = "",
    taxAddress: String = "",
    taxOffice: String = "",
    industry: String = "",
    openedOn: Date? = nil,
    blueReturnApproved: Bool = true,
    bookkeepingStyle: BookkeepingStyle = .doubleEntry,
    consumptionTaxStatus: ConsumptionTaxStatus = .exempt,
    invoiceRegistrationStatus: InvoiceRegistrationStatus = .unknown,
    invoiceRegistrationNumber: String? = nil,
    invoiceRegisteredOn: Date? = nil,
    invoiceCancelledOn: Date? = nil,
    taxAccountingMethod: TaxAccountingMethod = .taxInclusive,
    roundingRule: RoundingRule = .down,
    defaultTaxRate: TaxRate = .standard10
  ) {
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.ownerName = ownerName
    self.tradeName = tradeName
    self.postalAddress = postalAddress
    self.taxAddress = taxAddress
    self.taxOffice = taxOffice
    self.industry = industry
    self.openedOn = openedOn
    self.blueReturnApproved = blueReturnApproved
    self.bookkeepingStyle = bookkeepingStyle
    self.consumptionTaxStatus = consumptionTaxStatus
    self.invoiceRegistrationStatus = invoiceRegistrationStatus
    self.invoiceRegistrationNumber = invoiceRegistrationNumber
    self.invoiceRegisteredOn = invoiceRegisteredOn
    self.invoiceCancelledOn = invoiceCancelledOn
    self.taxAccountingMethod = taxAccountingMethod
    self.roundingRule = roundingRule
    self.defaultTaxRate = defaultTaxRate
  }
}
