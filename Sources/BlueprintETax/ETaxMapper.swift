import BlueprintDomain
import BlueprintFiling
import BlueprintTax
import Foundation

public enum ETaxMapper {
  public static func make(
    fiscalYear: Int,
    profile: BusinessProfile,
    blueReturn: BlueReturnPackage,
    deductionAssessment: BlueReturnDeductionAssessment,
    filingSummary: FilingWorkspaceSummary,
    deductions: [FilingDeduction],
    unsupportedCases: [UnsupportedFilingCase],
    taxRuleSet: TaxRuleSet,
    formRuleSet: FormRuleSet,
    ledgerFingerprint: String
  ) -> ETaxReturnData {
    let socialInsurance = deductions.filter { $0.kind == .socialInsurance }.sum
    let lifeInsurance = deductions.filter { $0.kind == .lifeInsurance }.sum
    let earthquakeInsurance = deductions.filter { $0.kind == .earthquakeInsurance }.sum
    let donations = deductions.filter { $0.kind == .donation }.sum
    let propertyDeduction = min(
      deductionAssessment.candidateAmount.yen,
      max(blueReturn.property.incomeBeforeDeduction.yen, 0)
    )
    let businessDeduction = min(
      max(deductionAssessment.candidateAmount.yen - propertyDeduction, 0),
      max(blueReturn.business.incomeBeforeDeduction.yen, 0)
    )
    let generalFields = [
      ETaxFieldValue(
        tag: "ABA00010", value: String(fiscalYear - 2018), path: ["ABA00000"],
        attributes: ["IDREF": "NENBUN"]),
      ETaxFieldValue(
        tag: "ABA00020", value: "1", path: ["ABA00000"],
        attributes: ["IDREF": "SHINKOKU_KBN"]),
      ETaxFieldValue(
        tag: "ABA00030", value: profile.taxOffice, path: ["ABA00000"],
        attributes: ["IDREF": "ZEIMUSHO"]),
      ETaxFieldValue(
        tag: "ABB00030", value: String(blueReturn.business.totalRevenue.yen),
        path: ["ABB00000", "ABB00010", "ABB00020"]),
      ETaxFieldValue(
        tag: "ABB00050", value: String(blueReturn.property.revenue.yen),
        path: ["ABB00000", "ABB00010"]),
      ETaxFieldValue(
        tag: "ABB00080", value: String(filingSummary.wageRevenue.yen),
        path: ["ABB00000", "ABB00010"]),
      ETaxFieldValue(
        tag: "ABB00300",
        value: String(blueReturn.business.incomeBeforeDeduction.yen - businessDeduction),
        path: ["ABB00000", "ABB00270", "ABB00280"]),
      ETaxFieldValue(
        tag: "ABB00340",
        value: String(blueReturn.property.incomeBeforeDeduction.yen - propertyDeduction),
        path: ["ABB00000", "ABB00270"]),
      ETaxFieldValue(
        tag: "ABB00450", value: String(socialInsurance), path: ["ABB00000", "ABB00420"]),
      ETaxFieldValue(
        tag: "ABB00470", value: String(lifeInsurance), path: ["ABB00000", "ABB00420"]),
      ETaxFieldValue(
        tag: "ABB00480", value: String(earthquakeInsurance), path: ["ABB00000", "ABB00420"]),
      ETaxFieldValue(
        tag: "ABB00490", value: String(donations), path: ["ABB00000", "ABB00420"]),
    ]
    let businessFields = [
      ETaxFieldValue(
        tag: "AMA00000", value: String(fiscalYear - 2018), attributes: ["IDREF": "NENBUN"]
      ),
      ETaxFieldValue(
        tag: "AMF00100", value: String(blueReturn.business.totalRevenue.yen),
        path: ["AMF00000", "AMF00010", "AMF00090"]),
      ETaxFieldValue(
        tag: "AMF00380", value: String(blueReturn.business.totalExpenses.yen),
        path: ["AMF00000", "AMF00010", "AMF00090", "AMF00180"]),
      ETaxFieldValue(
        tag: "AMF00390", value: String(blueReturn.business.incomeBeforeDeduction.yen),
        path: ["AMF00000", "AMF00010", "AMF00090"]),
      ETaxFieldValue(
        tag: "AMF00500", value: String(blueReturn.business.incomeBeforeDeduction.yen),
        path: ["AMF00000", "AMF00010", "AMF00090"]),
      ETaxFieldValue(
        tag: "AMF00510", value: String(businessDeduction),
        path: ["AMF00000", "AMF00010", "AMF00090"]),
      ETaxFieldValue(
        tag: "AMF00530",
        value: String(blueReturn.business.incomeBeforeDeduction.yen - businessDeduction),
        path: ["AMF00000", "AMF00010", "AMF00090"]
      ),
    ]
    let propertyFields = [
      ETaxFieldValue(
        tag: "ANA00000", value: String(fiscalYear - 2018), attributes: ["IDREF": "NENBUN"]),
      ETaxFieldValue(
        tag: "ANF00080", value: String(blueReturn.property.revenue.yen),
        path: ["ANF00000", "ANF00010", "ANF00070"]),
      ETaxFieldValue(
        tag: "ANF00110", value: String(blueReturn.property.revenue.yen),
        path: ["ANF00000", "ANF00010", "ANF00070"]),
      ETaxFieldValue(
        tag: "ANF00160", value: String(blueReturn.property.depreciation.yen),
        path: ["ANF00000", "ANF00010", "ANF00120"]),
      ETaxFieldValue(
        tag: "ANF00220", value: String(blueReturn.property.expenses.yen),
        path: ["ANF00000", "ANF00010", "ANF00120"]),
      ETaxFieldValue(
        tag: "ANF00230", value: String(blueReturn.property.incomeBeforeDeduction.yen),
        path: ["ANF00000", "ANF00010"]),
      ETaxFieldValue(
        tag: "ANF00250", value: String(blueReturn.property.incomeBeforeDeduction.yen),
        path: ["ANF00000", "ANF00010"]),
      ETaxFieldValue(
        tag: "ANF00260", value: String(propertyDeduction), path: ["ANF00000", "ANF00010"]),
      ETaxFieldValue(
        tag: "ANF00270",
        value: String(blueReturn.property.incomeBeforeDeduction.yen - propertyDeduction),
        path: ["ANF00000", "ANF00010"]),
    ]
    var checklist = formRuleSet.forms.map {
      ETaxChecklistItem(
        id: "included-\($0.id)",
        title: $0.name,
        detail: "\($0.id) v\($0.version) を出力します。",
        state: .included
      )
    }
    checklist += unsupportedCases.map {
      ETaxChecklistItem(
        id: "unsupported-\($0.id.uuidString)",
        title: $0.title,
        detail: $0.guidance,
        state: .additionalInput
      )
    }
    return ETaxReturnData(
      fiscalYear: fiscalYear,
      procedureID: formRuleSet.procedureID,
      procedureVersion: formRuleSet.procedureVersion,
      taxRuleSetID: taxRuleSet.id,
      formRuleSetID: formRuleSet.id,
      identity: ETaxIdentity(
        taxOfficeCode: profile.taxOfficeCode,
        taxOfficeName: profile.taxOffice,
        userID: profile.eTaxUserID,
        taxpayerName: profile.ownerName,
        taxpayerAddress: profile.taxAddress.isEmpty ? profile.postalAddress : profile.taxAddress
      ),
      forms: [
        ETaxFormData(formID: "KOA020", version: "23.0", fields: generalFields),
        ETaxFormData(formID: "KOA210", version: "11.0", fields: businessFields),
        ETaxFormData(formID: "KOA220", version: "8.0", fields: propertyFields),
      ],
      checklist: checklist,
      ledgerFingerprint: ledgerFingerprint
    )
  }
}

extension [FilingDeduction] {
  fileprivate var sum: Int64 {
    reduce(0) { $0 + $1.amount.yen }
  }
}
