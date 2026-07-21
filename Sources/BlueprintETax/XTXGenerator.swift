import BlueprintDomain
import CryptoKit
import Foundation

public enum XTXGenerationError: Error, Equatable, Sendable {
  case validationFailed([ETaxValidationIssue])
}

public enum XTXGenerator {
  public static func generate(
    _ returnData: ETaxReturnData,
    validationIssues: [ETaxValidationIssue],
    generatedAt: Date = Date()
  ) throws -> ETaxGeneratedPackage {
    let errors = validationIssues.filter { $0.severity == .error }
    guard errors.isEmpty else { throw XTXGenerationError.validationFailed(errors) }
    let creationDay = ISO8601DateFormatter.string(
      from: generatedAt,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      formatOptions: [.withFullDate]
    )
    let forms = returnData.forms.map { renderForm($0, creationDay: creationDay) }.joined(
      separator: "\n")
    let identity = returnData.identity
    let year = returnData.fiscalYear - 2018
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <DATA xmlns="http://xml.e-tax.nta.go.jp/XSD/shotoku"
            xmlns:gen="http://xml.e-tax.nta.go.jp/XSD/general"
            xmlns:kyo="http://xml.e-tax.nta.go.jp/XSD/kyotsu"
            xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            id="DATA">
        <\(returnData.procedureID) VR="\(escaped(returnData.procedureVersion))" id="\(returnData.procedureID)">
          <CATALOG id="CATALOG">
            <rdf:RDF />
          </CATALOG>
          <CONTENTS id="CONTENTS">
            <IT VR="1.5" id="IT">
              <ZEIMUSHO ID="ZEIMUSHO">
                <gen:zeimusho_CD>\(escaped(identity.taxOfficeCode))</gen:zeimusho_CD>
                <gen:zeimusho_NM>\(escaped(identity.taxOfficeName.replacingOccurrences(of: "税務署", with: "")))</gen:zeimusho_NM>
              </ZEIMUSHO>
              <NOZEISHA_ID ID="NOZEISHA_ID">\(escaped(identity.userID))</NOZEISHA_ID>
              <NOZEISHA_NM ID="NOZEISHA_NM">\(escaped(identity.taxpayerName))</NOZEISHA_NM>
              <NOZEISHA_ADR ID="NOZEISHA_ADR">\(escaped(identity.taxpayerAddress))</NOZEISHA_ADR>
              <TETSUZUKI ID="TETSUZUKI">
                <procedure_CD>\(returnData.procedureID)</procedure_CD>
              </TETSUZUKI>
              <NENBUN ID="NENBUN">
                <gen:era>5</gen:era>
                <gen:yy>\(year)</gen:yy>
              </NENBUN>
              <SHINKOKU_KBN ID="SHINKOKU_KBN">
                <kubun_CD>1</kubun_CD>
              </SHINKOKU_KBN>
            </IT>
      \(forms)
          </CONTENTS>
        </\(returnData.procedureID)>
      </DATA>
      """
    let data = Data(xml.utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ETaxGeneratedPackage(
      fileName: "blue-print-\(returnData.fiscalYear).xtx",
      data: data,
      hash: hash
    )
  }

  public static func ledgerFingerprint(parts: [String]) -> String {
    let payload = parts.joined(separator: "|")
    return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func renderForm(_ form: ETaxFormData, creationDay: String) -> String {
    let fields = renderFields(form.fields, depth: 0, indentation: "              ")
    return """
          <\(form.formID) VR="\(escaped(form.version))" id="\(form.id)"
              softNM="Blue-Print" sakuseiNM="Blue-Print \(BlueprintVersions.app)" sakuseiDay="\(creationDay)">
            <\(form.formID)-\(form.page) page="\(form.page)">
      \(fields)
            </\(form.formID)-\(form.page)>
          </\(form.formID)>
      """
  }

  private static func renderFields(
    _ fields: [ETaxFieldValue],
    depth: Int,
    indentation: String
  ) -> String {
    var output: [String] = []
    var index = 0
    while index < fields.count {
      let field = fields[index]
      if field.path.count == depth {
        let attributes = field.attributes.sorted { $0.key < $1.key }
          .map { " \($0.key)=\"\(escaped($0.value))\"" }
          .joined()
        if field.attributes.isEmpty {
          output.append("\(indentation)<\(field.tag)>\(escaped(field.value))</\(field.tag)>")
        } else {
          output.append("\(indentation)<\(field.tag)\(attributes) />")
        }
        index += 1
        continue
      }
      let container = field.path[depth]
      var end = index + 1
      while end < fields.count, fields[end].path.count > depth,
        fields[end].path[depth] == container
      {
        end += 1
      }
      let nested = renderFields(
        Array(fields[index..<end]),
        depth: depth + 1,
        indentation: indentation + "  "
      )
      output.append("\(indentation)<\(container)>\n\(nested)\n\(indentation)</\(container)>")
      index = end
    }
    return output.joined(separator: "\n")
  }

  private static func escaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
