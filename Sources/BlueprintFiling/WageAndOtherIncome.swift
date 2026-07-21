import BlueprintDomain
import Foundation

public struct WageWithholdingStatement: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var payerName: String
  public var paymentAmount: Money
  public var withholdingTax: Money
  public var socialInsurance: Money
  public var evidenceDocumentID: EntityID?
  public var reviewState: FilingReviewState

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    payerName: String,
    paymentAmount: Money,
    withholdingTax: Money,
    socialInsurance: Money,
    evidenceDocumentID: EntityID? = nil,
    reviewState: FilingReviewState = .unconfirmed
  ) throws {
    guard !payerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FilingError.missingName
    }
    guard paymentAmount.yen >= 0, withholdingTax.yen >= 0, socialInsurance.yen >= 0 else {
      throw FilingError.invalidAmount
    }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.payerName = payerName
    self.paymentAmount = paymentAmount
    self.withholdingTax = withholdingTax
    self.socialInsurance = socialInsurance
    self.evidenceDocumentID = evidenceDocumentID
    self.reviewState = reviewState
  }
}

public enum OtherIncomeKind: String, Codable, CaseIterable, Sendable {
  case miscellaneous
  case publicPension
  case temporary
  case retirement
}

public struct OtherIncomeEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var kind: OtherIncomeKind
  public var title: String
  public var revenue: Money
  public var expenses: Money
  public var withholdingTax: Money
  public var evidenceDocumentID: EntityID?
  public var reviewState: FilingReviewState

  public var income: Money { Money(yen: revenue.yen - expenses.yen) }

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    kind: OtherIncomeKind,
    title: String,
    revenue: Money,
    expenses: Money = .zero,
    withholdingTax: Money = .zero,
    evidenceDocumentID: EntityID? = nil,
    reviewState: FilingReviewState = .unconfirmed
  ) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FilingError.missingName
    }
    guard revenue.yen >= 0, expenses.yen >= 0, withholdingTax.yen >= 0 else {
      throw FilingError.invalidAmount
    }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.kind = kind
    self.title = title
    self.revenue = revenue
    self.expenses = expenses
    self.withholdingTax = withholdingTax
    self.evidenceDocumentID = evidenceDocumentID
    self.reviewState = reviewState
  }
}

public enum DeductionKind: String, Codable, CaseIterable, Sendable {
  case medical
  case socialInsurance
  case lifeInsurance
  case earthquakeInsurance
  case donation
  case dependent
  case other
}

public struct FilingDeduction: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var kind: DeductionKind
  public var title: String
  public var amount: Money
  public var evidenceDocumentID: EntityID?
  public var reviewState: FilingReviewState

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    kind: DeductionKind,
    title: String,
    amount: Money,
    evidenceDocumentID: EntityID? = nil,
    reviewState: FilingReviewState = .unconfirmed
  ) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FilingError.missingName
    }
    guard amount.yen >= 0 else { throw FilingError.invalidAmount }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.kind = kind
    self.title = title
    self.amount = amount
    self.evidenceDocumentID = evidenceDocumentID
    self.reviewState = reviewState
  }
}

public struct UnsupportedFilingCase: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var title: String
  public var guidance: String
  public var state: FilingReviewState

  public init(
    id: EntityID = UUID(), fiscalYearID: EntityID, title: String, guidance: String,
    state: FilingReviewState = .additionalETaxInput
  ) {
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.title = title
    self.guidance = guidance
    self.state = state
  }
}
