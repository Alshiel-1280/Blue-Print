import BlueprintDomain

public protocol FilingRepository: Sendable {
  func saveWorkspace(_ workspace: FilingWorkspace) throws
  func workspace(fiscalYearID: EntityID) throws -> FilingWorkspace?
  func saveWage(_ wage: WageWithholdingStatement) throws
  func wages(fiscalYearID: EntityID) throws -> [WageWithholdingStatement]
  func saveProperty(_ property: FilingProperty) throws
  func properties(fiscalYearID: EntityID) throws -> [FilingProperty]
  func saveRentalEntry(_ entry: RentalLedgerEntry) throws
  func rentalEntries(fiscalYearID: EntityID) throws -> [RentalLedgerEntry]
  func saveSecuritiesReport(_ report: SecuritiesAnnualReport) throws
  func securitiesReports(fiscalYearID: EntityID) throws -> [SecuritiesAnnualReport]
  func saveLossCarryforward(_ carryforward: StockLossCarryforward) throws
  func lossCarryforwards(fiscalYearID: EntityID) throws -> [StockLossCarryforward]
  func saveOtherIncome(_ income: OtherIncomeEntry) throws
  func otherIncome(fiscalYearID: EntityID) throws -> [OtherIncomeEntry]
  func saveDeduction(_ deduction: FilingDeduction) throws
  func deductions(fiscalYearID: EntityID) throws -> [FilingDeduction]
  func saveUnsupportedCase(_ unsupportedCase: UnsupportedFilingCase) throws
  func unsupportedCases(fiscalYearID: EntityID) throws -> [UnsupportedFilingCase]
}
