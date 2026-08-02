import BlueprintDomain
import Foundation

public enum RuleSetError: Error, Equatable, Sendable {
  case invalidEffectivePeriod
  case duplicateRuleSet(String)
  case unsupportedYear(Int)
}

public struct RuleSource: Codable, Equatable, Hashable, Sendable {
  public let title: String
  public let url: String
  public let checkedAt: Date

  public init(title: String, url: String, checkedAt: Date) {
    self.title = title
    self.url = url
    self.checkedAt = checkedAt
  }
}

public struct RuleEffectivePeriod: Codable, Equatable, Hashable, Sendable {
  public let firstYear: Int
  public let lastYear: Int

  public init(firstYear: Int, lastYear: Int) throws {
    guard firstYear <= lastYear else { throw RuleSetError.invalidEffectivePeriod }
    self.firstYear = firstYear
    self.lastYear = lastYear
  }

  public func contains(_ year: Int) -> Bool {
    (firstYear...lastYear).contains(year)
  }
}

public struct BlueReturnDeductionRule: Codable, Equatable, Hashable, Sendable {
  public let electronicMaximum: Money
  public let doubleEntryMaximum: Money
  public let basicMaximum: Money

  public init(
    electronicMaximum: Money,
    doubleEntryMaximum: Money,
    basicMaximum: Money
  ) {
    self.electronicMaximum = electronicMaximum
    self.doubleEntryMaximum = doubleEntryMaximum
    self.basicMaximum = basicMaximum
  }
}

public struct TaxRuleSet: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let revision: String
  public let effectivePeriod: RuleEffectivePeriod
  public let blueReturnDeduction: BlueReturnDeductionRule
  public let sources: [RuleSource]

  public init(
    id: String,
    revision: String,
    effectivePeriod: RuleEffectivePeriod,
    blueReturnDeduction: BlueReturnDeductionRule,
    sources: [RuleSource]
  ) {
    self.id = id
    self.revision = revision
    self.effectivePeriod = effectivePeriod
    self.blueReturnDeduction = blueReturnDeduction
    self.sources = sources
  }
}

public enum ETaxFieldDataType: String, Codable, CaseIterable, Sendable {
  case text
  case integer
  case code
}

public struct ETaxFieldDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let tag: String
  public let label: String
  public let dataType: ETaxFieldDataType
  public let isRequired: Bool
  public let maximumDigits: Int?
  public let allowedCodes: Set<String>
  public let permitsNegative: Bool

  public var id: String { tag }

  public init(
    tag: String,
    label: String,
    dataType: ETaxFieldDataType,
    isRequired: Bool = false,
    maximumDigits: Int? = nil,
    allowedCodes: Set<String> = [],
    permitsNegative: Bool = false
  ) {
    self.tag = tag
    self.label = label
    self.dataType = dataType
    self.isRequired = isRequired
    self.maximumDigits = maximumDigits
    self.allowedCodes = allowedCodes
    self.permitsNegative = permitsNegative
  }
}

public struct FormDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  public let maximumPages: Int

  public init(id: String, name: String, version: String, maximumPages: Int) {
    self.id = id
    self.name = name
    self.version = version
    self.maximumPages = maximumPages
  }
}

public struct FormRuleSet: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let revision: String
  public let effectivePeriod: RuleEffectivePeriod
  public let procedureID: String
  public let procedureVersion: String
  public let forms: [FormDefinition]
  public let fields: [ETaxFieldDefinition]
  public let sources: [RuleSource]

  public init(
    id: String,
    revision: String,
    effectivePeriod: RuleEffectivePeriod,
    procedureID: String,
    procedureVersion: String,
    forms: [FormDefinition],
    fields: [ETaxFieldDefinition],
    sources: [RuleSource]
  ) {
    self.id = id
    self.revision = revision
    self.effectivePeriod = effectivePeriod
    self.procedureID = procedureID
    self.procedureVersion = procedureVersion
    self.forms = forms
    self.fields = fields
    self.sources = sources
  }
}

public struct RuleSetDifference: Equatable, Sendable {
  public let addedForms: [FormDefinition]
  public let removedForms: [FormDefinition]
  public let changedForms: [FormDefinition]
  public let addedFields: [ETaxFieldDefinition]
  public let removedFields: [ETaxFieldDefinition]
  public let changedFields: [ETaxFieldDefinition]

  public var affectedItems: [String] {
    addedForms.map { "帳票追加: \($0.name)" }
      + removedForms.map { "帳票削除: \($0.name)" }
      + changedForms.map { "帳票変更: \($0.name)" }
      + addedFields.map { "項目追加: \($0.label)" }
      + removedFields.map { "項目削除: \($0.label)" }
      + changedFields.map { "項目変更: \($0.label)" }
  }
}

public struct RuleCatalog: Equatable, Sendable {
  public let taxRuleSets: [TaxRuleSet]
  public let formRuleSets: [FormRuleSet]

  public init(taxRuleSets: [TaxRuleSet] = [], formRuleSets: [FormRuleSet] = []) {
    self.taxRuleSets = taxRuleSets
    self.formRuleSets = formRuleSets
  }

  public func adding(taxRuleSet: TaxRuleSet, formRuleSet: FormRuleSet) throws -> RuleCatalog {
    guard !taxRuleSets.contains(where: { $0.id == taxRuleSet.id }) else {
      throw RuleSetError.duplicateRuleSet(taxRuleSet.id)
    }
    guard !formRuleSets.contains(where: { $0.id == formRuleSet.id }) else {
      throw RuleSetError.duplicateRuleSet(formRuleSet.id)
    }
    return RuleCatalog(
      taxRuleSets: taxRuleSets + [taxRuleSet],
      formRuleSets: formRuleSets + [formRuleSet]
    )
  }

  public func rules(for year: Int) throws -> (TaxRuleSet, FormRuleSet) {
    guard let tax = taxRuleSets.first(where: { $0.effectivePeriod.contains(year) }),
      let form = formRuleSets.first(where: { $0.effectivePeriod.contains(year) })
    else { throw RuleSetError.unsupportedYear(year) }
    return (tax, form)
  }

  public static func difference(from old: FormRuleSet, to new: FormRuleSet) -> RuleSetDifference {
    let oldForms = Dictionary(uniqueKeysWithValues: old.forms.map { ($0.id, $0) })
    let newForms = Dictionary(uniqueKeysWithValues: new.forms.map { ($0.id, $0) })
    let oldFields = Dictionary(uniqueKeysWithValues: old.fields.map { ($0.tag, $0) })
    let newFields = Dictionary(uniqueKeysWithValues: new.fields.map { ($0.tag, $0) })
    return RuleSetDifference(
      addedForms: new.forms.filter { oldForms[$0.id] == nil },
      removedForms: old.forms.filter { newForms[$0.id] == nil },
      changedForms: new.forms.filter { oldForms[$0.id] != nil && oldForms[$0.id] != $0 },
      addedFields: new.fields.filter { oldFields[$0.tag] == nil },
      removedFields: old.fields.filter { newFields[$0.tag] == nil },
      changedFields: new.fields.filter { oldFields[$0.tag] != nil && oldFields[$0.tag] != $0 }
    )
  }
}

public enum OfficialRules2025 {
  public static let supportedYears = [2025]
  public static let latestSupportedYear = 2025
  public static let tax = try! OfficialRulePackages.store.taxRule(for: 2025)
  public static let form = try! OfficialRulePackages.store.formRule(for: 2025)
  public static let catalog = RuleCatalog(taxRuleSets: [tax], formRuleSets: [form])
}
