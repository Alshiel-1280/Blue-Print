import BlueprintDomain

public protocol ClosingRepository: Sendable {
  func saveAsset(_ asset: FixedAsset) throws
  func asset(id: EntityID) throws -> FixedAsset?
  func assets(fiscalYearID: EntityID) throws -> [FixedAsset]
  func saveHouseholdRule(_ rule: HouseholdAllocationRule) throws
  func householdRules() throws -> [HouseholdAllocationRule]
  func saveAccrualTemplate(_ template: AccrualTemplate) throws
  func accrualTemplates() throws -> [AccrualTemplate]
  func saveInventory(_ inventory: InventoryClosing, fiscalYearID: EntityID) throws
  func inventory(fiscalYearID: EntityID) throws -> InventoryClosing?
}
