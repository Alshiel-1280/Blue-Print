import BlueprintDomain
import Foundation

public enum FilingError: Error, Equatable, Sendable {
  case invalidAmount
  case invalidLossCarryforward
  case missingName
  case mismatchedFiscalYear
}

public enum FilingReviewState: String, Codable, CaseIterable, Sendable {
  case unconfirmed
  case needsDecision
  case additionalETaxInput
  case confirmed
}

public struct FilingAttachment: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let evidenceDocumentID: EntityID
  public var title: String
  public var category: String

  public init(
    id: EntityID = UUID(), evidenceDocumentID: EntityID, title: String, category: String
  ) {
    self.id = id
    self.evidenceDocumentID = evidenceDocumentID
    self.title = title
    self.category = category
  }
}

public struct BusinessIncomeSnapshot: Codable, Equatable, Sendable {
  public let revenue: Money
  public let expenses: Money
  public let income: Money
  public let generatedAt: Date
  public let appVersion: String
  public let ruleVersion: String

  public init(
    revenue: Money,
    expenses: Money,
    income: Money,
    generatedAt: Date,
    appVersion: String = BlueprintVersions.app,
    ruleVersion: String = BlueprintVersions.taxRuleSet
  ) {
    self.revenue = revenue
    self.expenses = expenses
    self.income = income
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.ruleVersion = ruleVersion
  }
}

public struct FilingReviewItem: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var title: String
  public var detail: String
  public var state: FilingReviewState

  public init(
    id: EntityID = UUID(), title: String, detail: String, state: FilingReviewState
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.state = state
  }
}

public struct FilingWorkspace: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let fiscalYearID: EntityID
  public var attachments: [FilingAttachment]
  public var reviewItems: [FilingReviewItem]

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    attachments: [FilingAttachment] = [],
    reviewItems: [FilingReviewItem] = []
  ) {
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.attachments = attachments
    self.reviewItems = reviewItems
  }

  public var unresolvedItems: [FilingReviewItem] {
    reviewItems.filter { $0.state != .confirmed }
  }

  public mutating func attach(_ attachment: FilingAttachment, at date: Date) {
    if !attachments.contains(where: { $0.evidenceDocumentID == attachment.evidenceDocumentID }) {
      attachments.append(attachment)
      metadata.touch(at: date)
    }
  }
}

public struct FilingWorkspaceSummary: Equatable, Sendable {
  public let businessIncome: BusinessIncomeSnapshot
  public let propertyIncome: Money
  public let wageRevenue: Money
  public let securitiesIncome: Money
  public let otherIncome: Money
  public let withholdingTax: Money
  public let deductions: Money
  public let attentionCount: Int

  public var combinedIncomeAndRevenue: Money {
    Money(
      yen: businessIncome.income.yen + propertyIncome.yen + wageRevenue.yen + securitiesIncome.yen
        + otherIncome.yen)
  }
}

public enum FilingAggregation {
  public static func summary(
    fiscalYearID: EntityID,
    businessIncome: BusinessIncomeSnapshot,
    workspace: FilingWorkspace,
    wages: [WageWithholdingStatement],
    rentalEntries: [RentalLedgerEntry],
    securitiesReports: [SecuritiesAnnualReport],
    otherIncome: [OtherIncomeEntry],
    deductions: [FilingDeduction],
    unsupportedCases: [UnsupportedFilingCase]
  ) throws -> FilingWorkspaceSummary {
    let wageRows = wages.filter { $0.fiscalYearID == fiscalYearID }
    let rentalRows = rentalEntries.filter { $0.fiscalYearID == fiscalYearID }
    let securitiesRows = securitiesReports.filter { $0.fiscalYearID == fiscalYearID }
    let otherRows = otherIncome.filter { $0.fiscalYearID == fiscalYearID }
    let deductionRows = deductions.filter { $0.fiscalYearID == fiscalYearID }
    let unsupportedRows = unsupportedCases.filter { $0.fiscalYearID == fiscalYearID }
    guard workspace.fiscalYearID == fiscalYearID else { throw FilingError.mismatchedFiscalYear }

    let property = PropertyIncomeReport.make(entries: rentalRows)
    let securitiesIncome = securitiesRows.reduce(Int64(0)) {
      $0 + $1.capitalGainOrLoss.yen + $1.dividendAmount.yen
    }
    let withholding =
      wageRows.reduce(Int64(0)) { $0 + $1.withholdingTax.yen }
      + securitiesRows.reduce(Int64(0)) {
        $0 + $1.nationalWithholdingTax.yen + $1.localWithholdingTax.yen
          + $1.dividendWithholdingTax.yen
      }
      + otherRows.reduce(Int64(0)) { $0 + $1.withholdingTax.yen }
    let workspaceAttention = workspace.unresolvedItems.count
    let wageAttention = wageRows.filter { $0.reviewState != .confirmed }.count
    let securitiesAttention = securitiesRows.filter { $0.reviewState != .confirmed }.count
    let otherAttention = otherRows.filter { $0.reviewState != .confirmed }.count
    let deductionAttention = deductionRows.filter { $0.reviewState != .confirmed }.count
    let unsupportedAttention = unsupportedRows.filter { $0.state != .confirmed }.count
    let attention =
      workspaceAttention + wageAttention + securitiesAttention + otherAttention
      + deductionAttention + unsupportedAttention

    return FilingWorkspaceSummary(
      businessIncome: businessIncome,
      propertyIncome: property.income,
      wageRevenue: Money(yen: wageRows.reduce(0) { $0 + $1.paymentAmount.yen }),
      securitiesIncome: Money(yen: securitiesIncome),
      otherIncome: Money(yen: otherRows.reduce(0) { $0 + $1.income.yen }),
      withholdingTax: Money(yen: withholding),
      deductions: Money(yen: deductionRows.reduce(0) { $0 + $1.amount.yen }),
      attentionCount: attention
    )
  }
}
