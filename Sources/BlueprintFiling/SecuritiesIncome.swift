import BlueprintDomain
import Foundation

public enum SecuritiesWithholdingKind: String, Codable, CaseIterable, Sendable {
  case withholding
  case noWithholding
}

public struct SecuritiesAnnualReport: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var brokerName: String
  public var accountName: String
  public var withholdingKind: SecuritiesWithholdingKind
  public var proceeds: Money
  public var acquisitionCost: Money
  public var nationalWithholdingTax: Money
  public var localWithholdingTax: Money
  public var dividendAmount: Money
  public var dividendWithholdingTax: Money
  public var evidenceDocumentID: EntityID?
  public var reviewState: FilingReviewState

  public var capitalGainOrLoss: Money { Money(yen: proceeds.yen - acquisitionCost.yen) }

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    brokerName: String,
    accountName: String,
    withholdingKind: SecuritiesWithholdingKind,
    proceeds: Money,
    acquisitionCost: Money,
    nationalWithholdingTax: Money = .zero,
    localWithholdingTax: Money = .zero,
    dividendAmount: Money = .zero,
    dividendWithholdingTax: Money = .zero,
    evidenceDocumentID: EntityID? = nil,
    reviewState: FilingReviewState = .needsDecision
  ) throws {
    guard !brokerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FilingError.missingName
    }
    guard proceeds.yen >= 0, acquisitionCost.yen >= 0, nationalWithholdingTax.yen >= 0,
      localWithholdingTax.yen >= 0, dividendAmount.yen >= 0, dividendWithholdingTax.yen >= 0
    else { throw FilingError.invalidAmount }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.brokerName = brokerName
    self.accountName = accountName
    self.withholdingKind = withholdingKind
    self.proceeds = proceeds
    self.acquisitionCost = acquisitionCost
    self.nationalWithholdingTax = nationalWithholdingTax
    self.localWithholdingTax = localWithholdingTax
    self.dividendAmount = dividendAmount
    self.dividendWithholdingTax = dividendWithholdingTax
    self.evidenceDocumentID = evidenceDocumentID
    self.reviewState = reviewState
  }
}

public struct StockLossCarryforward: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let fiscalYearID: EntityID
  public var sourceYear: Int
  public var broughtForward: Money
  public var currentYearLoss: Money
  public var utilized: Money

  public var carriedForward: Money {
    Money(yen: broughtForward.yen + currentYearLoss.yen - utilized.yen)
  }

  public init(
    id: EntityID = UUID(),
    fiscalYearID: EntityID,
    sourceYear: Int,
    broughtForward: Money,
    currentYearLoss: Money,
    utilized: Money
  ) throws {
    guard broughtForward.yen >= 0, currentYearLoss.yen >= 0, utilized.yen >= 0,
      utilized.yen <= broughtForward.yen + currentYearLoss.yen
    else { throw FilingError.invalidLossCarryforward }
    self.id = id
    self.fiscalYearID = fiscalYearID
    self.sourceYear = sourceYear
    self.broughtForward = broughtForward
    self.currentYearLoss = currentYearLoss
    self.utilized = utilized
  }
}
