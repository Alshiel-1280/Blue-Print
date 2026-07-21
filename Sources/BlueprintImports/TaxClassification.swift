import BlueprintDomain
import Foundation

public enum TaxSelection: String, Codable, CaseIterable, Sendable {
  case standard10Qualified
  case standard10Unregistered
  case reduced8Qualified
  case reduced8Unregistered
  case exempt
  case outOfScope

  public var taxRate: TaxRate {
    switch self {
    case .standard10Qualified, .standard10Unregistered: .standard10
    case .reduced8Qualified, .reduced8Unregistered: .reduced8
    case .exempt: .exempt
    case .outOfScope: .outOfScope
    }
  }

  public var invoiceStatus: InvoiceRegistrationStatus {
    switch self {
    case .standard10Qualified, .reduced8Qualified: .qualified
    case .standard10Unregistered, .reduced8Unregistered: .exemptOrUnregistered
    case .exempt, .outOfScope: .unknown
    }
  }
}

public struct TaxTreatment: Codable, Equatable, Sendable {
  public let selection: TaxSelection
  public let deductibleBasisPoints: Int
  public let roundingUnit: RoundingUnit

  public init(
    selection: TaxSelection,
    deductibleBasisPoints: Int,
    roundingUnit: RoundingUnit
  ) {
    self.selection = selection
    self.deductibleBasisPoints = deductibleBasisPoints
    self.roundingUnit = roundingUnit
  }
}

public enum TransitionalTaxRuleResolver {
  public static func resolve(
    selection: TaxSelection,
    transactionDate: Date,
    roundingUnit: RoundingUnit
  ) -> TaxTreatment {
    guard selection.invoiceStatus == .exemptOrUnregistered else {
      return TaxTreatment(
        selection: selection,
        deductibleBasisPoints: selection.taxRate.basisPoints == nil ? 0 : 10_000,
        roundingUnit: roundingUnit
      )
    }
    let calendar = Calendar(identifier: .gregorian)
    let firstReduction = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
    let secondReduction = calendar.date(from: DateComponents(year: 2029, month: 10, day: 1))!
    let ratio: Int
    if transactionDate < firstReduction {
      ratio = 8_000
    } else if transactionDate < secondReduction {
      ratio = 5_000
    } else {
      ratio = 0
    }
    return TaxTreatment(
      selection: selection,
      deductibleBasisPoints: ratio,
      roundingUnit: roundingUnit
    )
  }
}
