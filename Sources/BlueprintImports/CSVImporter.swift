import BlueprintDomain
import Foundation

public enum CSVImportError: Error, Equatable, Sendable {
  case unsupportedEncoding
  case emptyFile
  case invalidMapping
}

public struct CSVDetection: Equatable, Sendable {
  public let encoding: CSVEncoding
  public let delimiter: CSVDelimiter
  public let previewRows: [[String]]
}

public enum CSVImporter {
  public static func detect(_ data: Data) throws -> CSVDetection {
    guard !data.isEmpty else { throw CSVImportError.emptyFile }
    let decoded: (String, CSVEncoding)
    if let text = String(data: data, encoding: .utf8) {
      decoded = (text, .utf8)
    } else if let text = String(data: data, encoding: .shiftJIS) {
      decoded = (text, .shiftJIS)
    } else {
      throw CSVImportError.unsupportedEncoding
    }
    let delimiter = detectDelimiter(in: decoded.0)
    let rows = parseRows(decoded.0, delimiter: Character(delimiter.rawValue)).prefix(20)
    return CSVDetection(
      encoding: decoded.1,
      delimiter: delimiter,
      previewRows: Array(rows)
    )
  }

  public static func makeBatch(
    data: Data,
    filename: String,
    profile: ImportProfile,
    existing: [ImportedTransaction],
    importedAt: Date
  ) throws -> ImportBatch {
    let encoding: String.Encoding = profile.encoding == .utf8 ? .utf8 : .shiftJIS
    guard let text = String(data: data, encoding: encoding) else {
      throw CSVImportError.unsupportedEncoding
    }
    let rows = parseRows(text, delimiter: Character(profile.delimiter.rawValue))
    let batchID = UUID()
    let dataRows = profile.hasHeader ? rows.dropFirst() : rows[...]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP_POSIX")
    formatter.dateFormat = profile.mapping.dateFormat
    var transactions: [ImportedTransaction] = []
    var errors: [ImportRowError] = []
    let highestColumn =
      [
        profile.mapping.dateColumn,
        profile.mapping.amountColumn,
        profile.mapping.descriptionColumn,
        profile.mapping.externalIDColumn ?? 0,
        profile.mapping.balanceColumn ?? 0,
      ].max() ?? 0

    for (offset, row) in dataRows.enumerated() {
      let rowNumber = offset + (profile.hasHeader ? 2 : 1)
      guard row.count > highestColumn else {
        errors.append(
          ImportRowError(
            batchID: batchID,
            rowNumber: rowNumber,
            rawRow: row.joined(separator: profile.delimiter.rawValue),
            message: "列数がマッピングより少ないため隔離しました"
          ))
        continue
      }
      let dateText = row[profile.mapping.dateColumn].trimmingCharacters(in: .whitespaces)
      let amountText = row[profile.mapping.amountColumn]
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "¥", with: "")
        .trimmingCharacters(in: .whitespaces)
      guard let date = formatter.date(from: dateText), let amount = Int64(amountText) else {
        errors.append(
          ImportRowError(
            batchID: batchID,
            rowNumber: rowNumber,
            rawRow: row.joined(separator: profile.delimiter.rawValue),
            message: "日付または金額を解釈できないため隔離しました"
          ))
        continue
      }
      let externalID = profile.mapping.externalIDColumn.flatMap {
        row[$0].isEmpty ? nil : row[$0]
      }
      let runningBalance = profile.mapping.balanceColumn.flatMap { index -> Money? in
        let value = row[index].replacingOccurrences(of: ",", with: "")
        return Int64(value).map(Money.init(yen:))
      }
      var transaction = ImportedTransaction(
        batchID: batchID,
        rowNumber: rowNumber,
        transactionDate: date,
        amount: Money(yen: amount),
        description: row[profile.mapping.descriptionColumn],
        externalID: externalID,
        runningBalance: runningBalance
      )
      if let duplicate = existing.first(where: { $0.duplicateKey == transaction.duplicateKey }) {
        transaction.duplicateOfID = duplicate.id
        transaction.state = .needsReview
      }
      transactions.append(transaction)
    }
    let state: ImportBatchState = errors.isEmpty ? .imported : .partiallyFailed
    return ImportBatch(
      id: batchID,
      profileID: profile.id,
      sourceFilename: filename,
      importedAt: importedAt,
      state: state,
      transactions: transactions,
      errors: errors
    )
  }

  private static func detectDelimiter(in text: String) -> CSVDelimiter {
    let firstLine = text.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
    let counts: [(CSVDelimiter, Int)] = [
      (.comma, firstLine.filter { $0 == "," }.count),
      (.tab, firstLine.filter { $0 == "\t" }.count),
      (.semicolon, firstLine.filter { $0 == ";" }.count),
    ]
    return counts.max { $0.1 < $1.1 }?.0 ?? .comma
  }

  private static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "\"" {
        let next = text.index(after: index)
        if quoted, next < text.endIndex, text[next] == "\"" {
          field.append("\"")
          index = next
        } else {
          quoted.toggle()
        }
      } else if character == delimiter, !quoted {
        row.append(field)
        field = ""
      } else if character.isNewline, !quoted {
        if character == "\n" || !field.isEmpty || !row.isEmpty {
          row.append(field)
          if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
          row = []
          field = ""
        }
      } else {
        field.append(character)
      }
      index = text.index(after: index)
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }
}
