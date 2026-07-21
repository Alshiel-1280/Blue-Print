import BlueprintTax
import Foundation

public enum ETaxValidator {
  public static func validate(
    _ data: ETaxReturnData,
    rules: FormRuleSet,
    blueReturn: BlueReturnPackage
  ) -> [ETaxValidationIssue] {
    var issues = blueReturn.validationIssues.map {
      ETaxValidationIssue(fieldTag: nil, message: $0.message, severity: .error)
    }
    guard data.procedureID == rules.procedureID else {
      issues.append(
        ETaxValidationIssue(fieldTag: nil, message: "対象年度の手続IDと一致しません。", severity: .error))
      return issues
    }
    var values = data.forms.flatMap(\.fields).reduce(into: [String: String]()) { result, field in
      if result[field.tag] == nil { result[field.tag] = field.value }
    }
    values["IT.ZEIMUSHO.CD"] = data.identity.taxOfficeCode
    values["IT.NOZEISHA_ID"] = data.identity.userID
    values["IT.NOZEISHA_NM"] = data.identity.taxpayerName
    values["IT.NOZEISHA_ADR"] = data.identity.taxpayerAddress
    for field in rules.fields {
      let value = values[field.tag]
      if field.isRequired && (value?.isEmpty != false) {
        issues.append(
          ETaxValidationIssue(
            fieldTag: field.tag,
            message: "\(field.label)は必須です。",
            severity: .error
          ))
        continue
      }
      guard let value, !value.isEmpty else { continue }
      switch field.dataType {
      case .text:
        break
      case .integer:
        guard let integer = Int64(value) else {
          issues.append(typeIssue(field))
          continue
        }
        if !field.permitsNegative && integer < 0 {
          issues.append(
            ETaxValidationIssue(
              fieldTag: field.tag,
              message: "\(field.label)は0以上で入力してください。",
              severity: .error
            ))
        }
        if let maximumDigits = field.maximumDigits,
          value.trimmingCharacters(in: CharacterSet(charactersIn: "-+")).count > maximumDigits
        {
          issues.append(
            ETaxValidationIssue(
              fieldTag: field.tag,
              message: "\(field.label)は\(maximumDigits)桁以内で入力してください。",
              severity: .error
            ))
        }
      case .code:
        if !field.allowedCodes.isEmpty && !field.allowedCodes.contains(value) {
          issues.append(
            ETaxValidationIssue(
              fieldTag: field.tag,
              message: "\(field.label)の区分値が対象年度仕様にありません。",
              severity: .error
            ))
        }
      }
    }
    if blueReturn.business.totalAssets != blueReturn.business.totalLiabilitiesAndEquity {
      issues.append(
        ETaxValidationIssue(
          fieldTag: nil,
          message: "青色申告決算書の貸借が一致するまで出力できません。",
          severity: .error
        ))
    }
    if !data.identity.taxOfficeCode.allSatisfy(\.isNumber)
      || data.identity.taxOfficeCode.count != 5
    {
      issues.append(
        ETaxValidationIssue(
          fieldTag: "IT.ZEIMUSHO.CD",
          message: "税務署番号は公式一覧の5桁で入力してください。",
          severity: .error
        ))
    }
    if !data.identity.userID.allSatisfy(\.isNumber) || data.identity.userID.count != 16 {
      issues.append(
        ETaxValidationIssue(
          fieldTag: "IT.NOZEISHA_ID",
          message: "利用者識別番号は16桁で入力してください。",
          severity: .error
        ))
    }
    return issues
  }

  private static func typeIssue(_ field: ETaxFieldDefinition) -> ETaxValidationIssue {
    ETaxValidationIssue(
      fieldTag: field.tag,
      message: "\(field.label)は整数で入力してください。",
      severity: .error
    )
  }
}
