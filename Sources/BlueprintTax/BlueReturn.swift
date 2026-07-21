import BlueprintClosing
import BlueprintDomain
import BlueprintFiling
import Foundation

public enum BlueReturnValidationCode: String, Codable, Sendable {
  case profitAndLossMismatch
  case balanceSheetUnbalanced
  case businessSnapshotStale
  case missingOwnerName
  case missingTaxOffice
}

public struct BlueReturnValidationIssue: Codable, Equatable, Identifiable, Sendable {
  public let code: BlueReturnValidationCode
  public let message: String

  public var id: String { code.rawValue }

  public init(code: BlueReturnValidationCode, message: String) {
    self.code = code
    self.message = message
  }
}

public struct BlueReturnLine: Codable, Equatable, Identifiable, Sendable {
  public let code: String
  public let label: String
  public let amount: Money

  public var id: String { code }

  public init(code: String, label: String, amount: Money) {
    self.code = code
    self.label = label
    self.amount = amount
  }
}

public struct BusinessBlueReturnStatement: Codable, Equatable, Sendable {
  public let fiscalYear: Int
  public let ownerName: String
  public let tradeName: String
  public let revenueLines: [BlueReturnLine]
  public let expenseLines: [BlueReturnLine]
  public let assetLines: [BlueReturnLine]
  public let liabilityAndEquityLines: [BlueReturnLine]
  public let totalRevenue: Money
  public let totalExpenses: Money
  public let incomeBeforeDeduction: Money
  public let totalAssets: Money
  public let totalLiabilitiesAndEquity: Money
}

public struct PropertyBlueReturnStatement: Codable, Equatable, Sendable {
  public let fiscalYear: Int
  public let revenue: Money
  public let expenses: Money
  public let depreciation: Money
  public let incomeBeforeDeduction: Money
}

public struct BlueReturnPackage: Codable, Equatable, Sendable {
  public let business: BusinessBlueReturnStatement
  public let property: PropertyBlueReturnStatement
  public let validationIssues: [BlueReturnValidationIssue]
}

public struct BlueReturnDeductionAssessment: Codable, Equatable, Sendable {
  public let candidateAmount: Money
  public let missingRequirements: [String]

  public var isEligible: Bool { missingRequirements.isEmpty }
}

public enum BlueReturnMapper {
  public static func make(
    fiscalYear: Int,
    profile: BusinessProfile,
    profitAndLoss: ProfitAndLossReport,
    balanceSheet: BalanceSheetReport,
    businessSnapshot: BusinessIncomeSnapshot,
    propertyReport: PropertyIncomeReport
  ) -> BlueReturnPackage {
    var issues: [BlueReturnValidationIssue] = []
    if profitAndLoss.profit != balanceSheet.currentProfit {
      issues.append(
        BlueReturnValidationIssue(
          code: .profitAndLossMismatch,
          message: "損益計算書の利益と貸借対照表の当期利益が一致していません。"
        ))
    }
    if !balanceSheet.balances {
      issues.append(
        BlueReturnValidationIssue(
          code: .balanceSheetUnbalanced,
          message: "貸借対照表の資産合計と負債・資本合計が一致していません。"
        ))
    }
    if businessSnapshot.income != profitAndLoss.profit
      || businessSnapshot.revenue != profitAndLoss.totalRevenue
      || businessSnapshot.expenses != profitAndLoss.totalExpenses
    {
      issues.append(
        BlueReturnValidationIssue(
          code: .businessSnapshotStale,
          message: "申告ワークスペースの事業所得が最新の決算結果と一致していません。"
        ))
    }
    if profile.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(
        BlueReturnValidationIssue(code: .missingOwnerName, message: "事業主氏名を設定してください。"))
    }
    if profile.taxOffice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(
        BlueReturnValidationIssue(code: .missingTaxOffice, message: "提出先税務署を設定してください。"))
    }

    let business = BusinessBlueReturnStatement(
      fiscalYear: fiscalYear,
      ownerName: profile.ownerName,
      tradeName: profile.tradeName,
      revenueLines: profitAndLoss.revenue.map {
        BlueReturnLine(code: $0.accountCode, label: $0.accountName, amount: $0.amount)
      },
      expenseLines: profitAndLoss.expenses.map {
        BlueReturnLine(code: $0.accountCode, label: $0.accountName, amount: $0.amount)
      },
      assetLines: balanceSheet.assets.map {
        BlueReturnLine(code: $0.accountCode, label: $0.accountName, amount: $0.amount)
      },
      liabilityAndEquityLines: (balanceSheet.liabilities + balanceSheet.equity).map {
        BlueReturnLine(code: $0.accountCode, label: $0.accountName, amount: $0.amount)
      },
      totalRevenue: profitAndLoss.totalRevenue,
      totalExpenses: profitAndLoss.totalExpenses,
      incomeBeforeDeduction: profitAndLoss.profit,
      totalAssets: balanceSheet.totalAssets,
      totalLiabilitiesAndEquity: balanceSheet.totalLiabilitiesAndEquity
    )
    let property = PropertyBlueReturnStatement(
      fiscalYear: fiscalYear,
      revenue: propertyReport.revenue,
      expenses: propertyReport.expenses,
      depreciation: propertyReport.depreciation,
      incomeBeforeDeduction: propertyReport.income
    )
    return BlueReturnPackage(business: business, property: property, validationIssues: issues)
  }

  public static func deductionAssessment(
    profile: BusinessProfile,
    balanceSheet: BalanceSheetReport,
    taxRuleSet: TaxRuleSet,
    intendsElectronicFiling: Bool
  ) -> BlueReturnDeductionAssessment {
    var missing: [String] = []
    if !profile.blueReturnApproved { missing.append("青色申告の承認") }
    if profile.bookkeepingStyle != .doubleEntry { missing.append("複式簿記") }
    if !balanceSheet.balances { missing.append("貸借対照表の一致") }

    if missing.isEmpty && intendsElectronicFiling {
      return BlueReturnDeductionAssessment(
        candidateAmount: taxRuleSet.blueReturnDeduction.electronicMaximum,
        missingRequirements: []
      )
    }
    if missing.isEmpty {
      return BlueReturnDeductionAssessment(
        candidateAmount: taxRuleSet.blueReturnDeduction.doubleEntryMaximum,
        missingRequirements: ["65万円控除には期限内の電子申告等が必要です。"]
      )
    }
    return BlueReturnDeductionAssessment(
      candidateAmount: taxRuleSet.blueReturnDeduction.basicMaximum,
      missingRequirements: missing
    )
  }

  public static func preview(_ package: BlueReturnPackage) -> String {
    [
      "令和\(package.business.fiscalYear - 2018)年分 青色申告決算書 確認表示",
      "事業収入 \(package.business.totalRevenue.yen)円",
      "必要経費 \(package.business.totalExpenses.yen)円",
      "事業所得 \(package.business.incomeBeforeDeduction.yen)円",
      "資産合計 \(package.business.totalAssets.yen)円",
      "負債・資本合計 \(package.business.totalLiabilitiesAndEquity.yen)円",
      "不動産収入 \(package.property.revenue.yen)円",
      "不動産必要経費 \(package.property.expenses.yen)円",
      "不動産減価償却 \(package.property.depreciation.yen)円",
      "不動産所得 \(package.property.incomeBeforeDeduction.yen)円",
    ].joined(separator: "\n")
  }
}
