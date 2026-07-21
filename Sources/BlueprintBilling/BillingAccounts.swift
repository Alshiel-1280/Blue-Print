import BlueprintDomain

public struct InvoiceIssueAccounts: Equatable, Sendable {
  public let receivableAccountID: EntityID
  public let revenueAccountID: EntityID

  public init(receivableAccountID: EntityID, revenueAccountID: EntityID) {
    self.receivableAccountID = receivableAccountID
    self.revenueAccountID = revenueAccountID
  }
}

public struct ReceivableSettlementAccounts: Equatable, Sendable {
  public let receivableAccountID: EntityID
  public let bankAccountID: EntityID
  public let bankFeeAccountID: EntityID
  public let withholdingAccountID: EntityID
  public let discountAccountID: EntityID
  public let overpaymentAccountID: EntityID

  public init(
    receivableAccountID: EntityID,
    bankAccountID: EntityID,
    bankFeeAccountID: EntityID,
    withholdingAccountID: EntityID,
    discountAccountID: EntityID,
    overpaymentAccountID: EntityID
  ) {
    self.receivableAccountID = receivableAccountID
    self.bankAccountID = bankAccountID
    self.bankFeeAccountID = bankFeeAccountID
    self.withholdingAccountID = withholdingAccountID
    self.discountAccountID = discountAccountID
    self.overpaymentAccountID = overpaymentAccountID
  }
}

public struct VendorBillAccounts: Equatable, Sendable {
  public let expenseAccountID: EntityID
  public let payableAccountID: EntityID

  public init(expenseAccountID: EntityID, payableAccountID: EntityID) {
    self.expenseAccountID = expenseAccountID
    self.payableAccountID = payableAccountID
  }
}

public struct VendorPaymentAccounts: Equatable, Sendable {
  public let payableAccountID: EntityID
  public let bankAccountID: EntityID
  public let bankFeeAccountID: EntityID
  public let withholdingAccountID: EntityID

  public init(
    payableAccountID: EntityID,
    bankAccountID: EntityID,
    bankFeeAccountID: EntityID,
    withholdingAccountID: EntityID
  ) {
    self.payableAccountID = payableAccountID
    self.bankAccountID = bankAccountID
    self.bankFeeAccountID = bankFeeAccountID
    self.withholdingAccountID = withholdingAccountID
  }
}
