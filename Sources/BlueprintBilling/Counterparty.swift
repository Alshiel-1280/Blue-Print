import BlueprintDomain
import Foundation

public enum CounterpartyRole: String, Codable, CaseIterable, Hashable, Sendable {
  case customer
  case vendor
}

public struct Counterparty: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public var code: String
  public var displayName: String
  public var roles: Set<CounterpartyRole>
  public var postalCode: String
  public var address: String
  public var contactName: String
  public var email: String
  public var invoiceRegistrationStatus: InvoiceRegistrationStatus
  public var invoiceRegistrationNumber: String?
  public var paymentTermsDays: Int
  public var withholdingDefaultEnabled: Bool
  public var isActive: Bool

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    code: String,
    displayName: String,
    roles: Set<CounterpartyRole>,
    postalCode: String = "",
    address: String = "",
    contactName: String = "",
    email: String = "",
    invoiceRegistrationStatus: InvoiceRegistrationStatus = .unknown,
    invoiceRegistrationNumber: String? = nil,
    paymentTermsDays: Int = 30,
    withholdingDefaultEnabled: Bool = false,
    isActive: Bool = true
  ) {
    self.metadata = metadata
    self.code = code
    self.displayName = displayName
    self.roles = roles
    self.postalCode = postalCode
    self.address = address
    self.contactName = contactName
    self.email = email
    self.invoiceRegistrationStatus = invoiceRegistrationStatus
    self.invoiceRegistrationNumber = invoiceRegistrationNumber
    self.paymentTermsDays = max(paymentTermsDays, 0)
    self.withholdingDefaultEnabled = withholdingDefaultEnabled
    self.isActive = isActive
  }
}
