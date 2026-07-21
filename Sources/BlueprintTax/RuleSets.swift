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
  private static let checkedAt = Date(timeIntervalSince1970: 1_784_559_600)

  public static let tax = TaxRuleSet(
    id: "tax-2025.1",
    revision: "2025.1",
    effectivePeriod: try! RuleEffectivePeriod(firstYear: 2025, lastYear: 2025),
    blueReturnDeduction: BlueReturnDeductionRule(
      electronicMaximum: Money(yen: 650_000),
      doubleEntryMaximum: Money(yen: 550_000),
      basicMaximum: Money(yen: 100_000)
    ),
    sources: [
      RuleSource(
        title: "令和7年分 青色申告決算書・手引き",
        url: "https://www.nta.go.jp/taxes/shiraberu/shinkoku/syotoku/r07.htm",
        checkedAt: checkedAt
      )
    ]
  )

  public static let form = FormRuleSet(
    id: "form-2025.1",
    revision: "2025.1",
    effectivePeriod: try! RuleEffectivePeriod(firstYear: 2025, lastYear: 2025),
    procedureID: "RKO0010",
    procedureVersion: "25.0.0",
    forms: [
      FormDefinition(id: "KOA020", name: "所得税及び復興特別所得税申告書", version: "23.0", maximumPages: 8),
      FormDefinition(id: "KOA210", name: "青色申告決算書（一般用）", version: "11.0", maximumPages: 4),
      FormDefinition(id: "KOA220", name: "青色申告決算書（不動産所得用）", version: "8.0", maximumPages: 4),
    ],
    fields: [
      ETaxFieldDefinition(
        tag: "IT.ZEIMUSHO.CD", label: "税務署番号", dataType: .integer, isRequired: true,
        maximumDigits: 5),
      ETaxFieldDefinition(
        tag: "IT.NOZEISHA_ID", label: "利用者識別番号", dataType: .integer, isRequired: true,
        maximumDigits: 16),
      ETaxFieldDefinition(tag: "IT.NOZEISHA_NM", label: "氏名", dataType: .text, isRequired: true),
      ETaxFieldDefinition(tag: "IT.NOZEISHA_ADR", label: "納税地", dataType: .text, isRequired: true),
      ETaxFieldDefinition(
        tag: "ABA00010", label: "年分", dataType: .integer, isRequired: true, maximumDigits: 2),
      ETaxFieldDefinition(
        tag: "ABA00020", label: "申告書の種類", dataType: .code, isRequired: true,
        allowedCodes: ["1", "2", "3", "4"]),
      ETaxFieldDefinition(tag: "ABA00030", label: "税務署名", dataType: .text, isRequired: true),
      ETaxFieldDefinition(tag: "ABB00030", label: "事業収入", dataType: .integer, maximumDigits: 15),
      ETaxFieldDefinition(tag: "ABB00050", label: "不動産収入", dataType: .integer, maximumDigits: 15),
      ETaxFieldDefinition(tag: "ABB00080", label: "給与収入", dataType: .integer, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "ABB00300", label: "事業所得", dataType: .integer, maximumDigits: 15, permitsNegative: true
      ),
      ETaxFieldDefinition(
        tag: "ABB00340", label: "不動産所得", dataType: .integer, maximumDigits: 15,
        permitsNegative: true),
      ETaxFieldDefinition(tag: "ABB00450", label: "社会保険料控除", dataType: .integer, maximumDigits: 15),
      ETaxFieldDefinition(tag: "ABB00470", label: "生命保険料控除", dataType: .integer, maximumDigits: 6),
      ETaxFieldDefinition(tag: "ABB00480", label: "地震保険料控除", dataType: .integer, maximumDigits: 5),
      ETaxFieldDefinition(tag: "ABB00490", label: "寄附金控除", dataType: .integer, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "AMA00000", label: "一般用決算書の年分", dataType: .integer, isRequired: true, maximumDigits: 2),
      ETaxFieldDefinition(
        tag: "AMF00100", label: "売上（収入）金額", dataType: .integer, isRequired: true, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "AMF00380", label: "一般用の経費計", dataType: .integer, isRequired: true, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "AMF00390", label: "一般用の差引金額", dataType: .integer, isRequired: true, maximumDigits: 15,
        permitsNegative: true),
      ETaxFieldDefinition(
        tag: "AMF00500", label: "一般用の控除前所得", dataType: .integer, isRequired: true,
        maximumDigits: 15, permitsNegative: true),
      ETaxFieldDefinition(
        tag: "AMF00510", label: "一般用の青色申告特別控除", dataType: .integer, isRequired: true,
        maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "AMF00530", label: "一般用の所得金額", dataType: .integer, isRequired: true, maximumDigits: 15,
        permitsNegative: true),
      ETaxFieldDefinition(
        tag: "ANA00000", label: "不動産用決算書の年分", dataType: .integer, isRequired: true, maximumDigits: 2
      ),
      ETaxFieldDefinition(
        tag: "ANF00080", label: "賃貸料", dataType: .integer, isRequired: true, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "ANF00110", label: "不動産収入計", dataType: .integer, isRequired: true, maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "ANF00160", label: "不動産の減価償却費", dataType: .integer, isRequired: true, maximumDigits: 15
      ),
      ETaxFieldDefinition(
        tag: "ANF00220", label: "不動産の必要経費計", dataType: .integer, isRequired: true, maximumDigits: 15
      ),
      ETaxFieldDefinition(
        tag: "ANF00230", label: "不動産の差引金額", dataType: .integer, isRequired: true, maximumDigits: 15,
        permitsNegative: true),
      ETaxFieldDefinition(
        tag: "ANF00250", label: "不動産の控除前所得", dataType: .integer, isRequired: true,
        maximumDigits: 15, permitsNegative: true),
      ETaxFieldDefinition(
        tag: "ANF00260", label: "不動産の青色申告特別控除", dataType: .integer, isRequired: true,
        maximumDigits: 15),
      ETaxFieldDefinition(
        tag: "ANF00270", label: "不動産の所得金額", dataType: .integer, isRequired: true, maximumDigits: 15,
        permitsNegative: true),
    ],
    sources: [
      RuleSource(
        title: "e-Tax仕様書一覧（所得税 XML・帳票フィールド）",
        url: "https://www.e-tax.nta.go.jp/shiyo/shiyo3.htm",
        checkedAt: checkedAt
      ),
      RuleSource(
        title: "e-Tax WEB版 .xtx取込手順",
        url: "https://www.e-tax.nta.go.jp/toiawase/qa/e-taxweb/49.htm",
        checkedAt: checkedAt
      ),
    ]
  )

  public static let catalog = RuleCatalog(taxRuleSets: [tax], formRuleSets: [form])
}
