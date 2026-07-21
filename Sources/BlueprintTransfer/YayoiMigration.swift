import BlueprintDomain
import Foundation

public enum YayoiProduct: String, Codable, CaseIterable, Sendable {
  case desktopOrOnline
  case next

  public var maximumLinesPerEntry: Int {
    switch self {
    case .desktopOrOnline: 20
    case .next: 100
    }
  }
}

public enum YayoiMigrationState: String, Codable, Sendable {
  case preview
  case imported
  case partiallyFailed
  case cancelled
}

public struct YayoiTaxMapping: Codable, Equatable, Sendable {
  public var rate: TaxRate
  public var invoiceStatus: InvoiceRegistrationStatus
  public var deductibleBasisPoints: Int
  public var isTaxIncluded: Bool

  public init(
    rate: TaxRate,
    invoiceStatus: InvoiceRegistrationStatus = .unknown,
    deductibleBasisPoints: Int = 10_000,
    isTaxIncluded: Bool = true
  ) {
    self.rate = rate
    self.invoiceStatus = invoiceStatus
    self.deductibleBasisPoints = deductibleBasisPoints
    self.isTaxIncluded = isTaxIncluded
  }
}

public struct YayoiMigrationLine: Codable, Equatable, Sendable {
  public var sourceAccount: String
  public var sourceSubAccount: String?
  public var side: PostingSide
  public var amount: Money
  public var tax: YayoiTaxMapping

  public init(
    sourceAccount: String,
    sourceSubAccount: String? = nil,
    side: PostingSide,
    amount: Money,
    tax: YayoiTaxMapping
  ) {
    self.sourceAccount = sourceAccount
    self.sourceSubAccount = sourceSubAccount
    self.side = side
    self.amount = amount
    self.tax = tax
  }
}

public struct YayoiMigrationEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var date: Date
  public var description: String
  public var lines: [YayoiMigrationLine]
  public var sourceRows: ClosedRange<Int>

  public init(
    id: EntityID = UUID(),
    date: Date,
    description: String,
    lines: [YayoiMigrationLine],
    sourceRows: ClosedRange<Int>
  ) {
    self.id = id
    self.date = date
    self.description = description
    self.lines = lines
    self.sourceRows = sourceRows
  }

  public var debitTotal: Money {
    Money(yen: lines.filter { $0.side == .debit }.reduce(0) { $0 + $1.amount.yen })
  }

  public var creditTotal: Money {
    Money(yen: lines.filter { $0.side == .credit }.reduce(0) { $0 + $1.amount.yen })
  }

  public var isBalanced: Bool { debitTotal == creditTotal && debitTotal.yen > 0 }
}

public struct YayoiQuarantinedRow: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var rowNumber: Int
  public var rawRow: String
  public var reason: String

  public init(id: EntityID = UUID(), rowNumber: Int, rawRow: String, reason: String) {
    self.id = id
    self.rowNumber = rowNumber
    self.rawRow = rawRow
    self.reason = reason
  }
}

public struct YayoiAccountMapping: Codable, Equatable, Identifiable, Sendable {
  public var id: String { sourceAccount }
  public var sourceAccount: String
  public var targetAccountID: EntityID?
  public var targetAccountName: String?

  public init(
    sourceAccount: String,
    targetAccountID: EntityID? = nil,
    targetAccountName: String? = nil
  ) {
    self.sourceAccount = sourceAccount
    self.targetAccountID = targetAccountID
    self.targetAccountName = targetAccountName
  }
}

public struct YayoiSubAccountMapping: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(sourceAccount)|\(sourceSubAccount)" }
  public var sourceAccount: String
  public var sourceSubAccount: String
  public var targetSubAccountID: EntityID?
  public var targetSubAccountName: String?

  public init(
    sourceAccount: String,
    sourceSubAccount: String,
    targetSubAccountID: EntityID? = nil,
    targetSubAccountName: String? = nil
  ) {
    self.sourceAccount = sourceAccount
    self.sourceSubAccount = sourceSubAccount
    self.targetSubAccountID = targetSubAccountID
    self.targetSubAccountName = targetSubAccountName
  }
}

public struct YayoiMigrationBatch: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public var sourceFilename: String
  public var product: YayoiProduct
  public var importedAt: Date
  public var state: YayoiMigrationState
  public var entries: [YayoiMigrationEntry]
  public var quarantinedRows: [YayoiQuarantinedRow]
  public var accountMappings: [YayoiAccountMapping]
  public var subAccountMappings: [YayoiSubAccountMapping]

  public init(
    id: EntityID = UUID(),
    sourceFilename: String,
    product: YayoiProduct,
    importedAt: Date,
    state: YayoiMigrationState = .preview,
    entries: [YayoiMigrationEntry],
    quarantinedRows: [YayoiQuarantinedRow],
    accountMappings: [YayoiAccountMapping],
    subAccountMappings: [YayoiSubAccountMapping] = []
  ) {
    self.id = id
    self.sourceFilename = sourceFilename
    self.product = product
    self.importedAt = importedAt
    self.state = state
    self.entries = entries
    self.quarantinedRows = quarantinedRows
    self.accountMappings = accountMappings
    self.subAccountMappings = subAccountMappings
  }

  public mutating func cancel() {
    guard state != .imported else { return }
    state = .cancelled
  }

  public var balanceDifference: Money {
    Money(
      yen: entries.reduce(0) { partial, entry in
        partial + entry.debitTotal.yen - entry.creditTotal.yen
      })
  }

  public var accountBalanceComparison: [YayoiAccountBalanceComparison] {
    accountMappings.map { mapping in
      let signed = entries.flatMap(\.lines)
        .filter { $0.sourceAccount == mapping.sourceAccount }
        .reduce(Int64(0)) { partial, line in
          partial + (line.side == .debit ? line.amount.yen : -line.amount.yen)
        }
      return YayoiAccountBalanceComparison(
        sourceAccount: mapping.sourceAccount,
        targetAccountName: mapping.targetAccountName,
        sourceSignedDebitYen: signed,
        targetSignedDebitYen: mapping.targetAccountID == nil ? nil : signed
      )
    }.sorted { $0.sourceAccount < $1.sourceAccount }
  }
}

public struct YayoiAccountBalanceComparison: Equatable, Identifiable, Sendable {
  public var id: String { sourceAccount }
  public var sourceAccount: String
  public var targetAccountName: String?
  public var sourceSignedDebitYen: Int64
  public var targetSignedDebitYen: Int64?

  public init(
    sourceAccount: String,
    targetAccountName: String?,
    sourceSignedDebitYen: Int64,
    targetSignedDebitYen: Int64?
  ) {
    self.sourceAccount = sourceAccount
    self.targetAccountName = targetAccountName
    self.sourceSignedDebitYen = sourceSignedDebitYen
    self.targetSignedDebitYen = targetSignedDebitYen
  }

  public var differenceYen: Int64? {
    targetSignedDebitYen.map { $0 - sourceSignedDebitYen }
  }
}

public enum YayoiMigrationError: Error, Equatable, Sendable {
  case emptyFile
  case unsupportedEncoding
  case noImportableRows
  case cancelledBatch
  case unmappedAccount(String)
}

public enum YayoiTaxMapper {
  public static func map(_ source: String) -> YayoiTaxMapping? {
    let normalized = source.replacingOccurrences(of: " ", with: "")
    if normalized.isEmpty || normalized == "対象外" {
      return YayoiTaxMapping(rate: .exempt, deductibleBasisPoints: 0)
    }

    let rate: TaxRate
    if normalized.contains("軽減8%") {
      rate = .reduced8
    } else if normalized.contains("10%") {
      rate = .standard10
    } else if normalized.contains("8%") {
      rate = .reduced8
    } else if normalized.contains("非課税") || normalized.contains("不課税") {
      rate = .exempt
    } else {
      return nil
    }

    let status: InvoiceRegistrationStatus
    if normalized.contains("適格") {
      status = .qualified
    } else if normalized.contains("区分") {
      status = .exemptOrUnregistered
    } else {
      status = .unknown
    }

    let deductible: Int
    if normalized.contains("控不") {
      deductible = 0
    } else if let percent = [100, 80, 70, 50, 30].first(where: { normalized.contains("\($0)%") }) {
      deductible = percent * 100
    } else {
      deductible = 10_000
    }
    return YayoiTaxMapping(
      rate: rate,
      invoiceStatus: status,
      deductibleBasisPoints: deductible,
      isTaxIncluded: normalized.contains("込") || normalized.contains("内")
    )
  }
}

public enum YayoiCSVImporter {
  private struct ParsedRow {
    var number: Int
    var raw: String
    var columns: [String]
  }

  public static func preview(
    data: Data,
    filename: String,
    product: YayoiProduct,
    availableAccounts: [Account],
    importedAt: Date = Date()
  ) throws -> YayoiMigrationBatch {
    guard !data.isEmpty else { throw YayoiMigrationError.emptyFile }
    guard let text = decode(data) else { throw YayoiMigrationError.unsupportedEncoding }
    let parsedRows = parseRows(text)
    if parsedRows.first.map({
      !["2000", "2111", "2110", "2100", "2101"].contains($0.columns.first ?? "")
    })
      == true
    {
      return try openingBalancePreview(
        rows: parsedRows,
        filename: filename,
        product: product,
        availableAccounts: availableAccounts,
        importedAt: importedAt
      )
    }
    var entries: [YayoiMigrationEntry] = []
    var quarantined: [YayoiQuarantinedRow] = []
    var group: [ParsedRow] = []

    func quarantine(_ rows: [ParsedRow], _ reason: String) {
      for row in rows {
        quarantined.append(
          YayoiQuarantinedRow(rowNumber: row.number, rawRow: row.raw, reason: reason))
      }
    }

    func finishGroup(_ rows: [ParsedRow]) {
      guard !rows.isEmpty else { return }
      do {
        entries.append(try makeEntry(rows))
      } catch {
        quarantine(rows, String(describing: error))
      }
    }

    for row in parsedRows {
      guard row.columns.count >= 17 else {
        quarantine([row], "25列形式として必要な17列目までを確認できません")
        continue
      }
      switch row.columns[0] {
      case "2000", "2111":
        finishGroup(group)
        group = []
        finishGroup([row])
      case "2110":
        finishGroup(group)
        group = [row]
      case "2100":
        guard !group.isEmpty else {
          quarantine([row], "複合仕訳の開始行がありません")
          continue
        }
        group.append(row)
      case "2101":
        guard !group.isEmpty else {
          quarantine([row], "複合仕訳の開始行がありません")
          continue
        }
        group.append(row)
        if group.count > product.maximumLinesPerEntry {
          quarantine(group, "製品別の複合仕訳上限を超えています")
        } else {
          finishGroup(group)
        }
        group = []
      default:
        quarantine([row], "未対応の識別フラグ: \(row.columns[0])")
      }
    }
    if !group.isEmpty { quarantine(group, "複合仕訳の最終行がありません") }
    guard !entries.isEmpty || !quarantined.isEmpty else {
      throw YayoiMigrationError.noImportableRows
    }

    let sourceAccounts = Set(entries.flatMap(\.lines).map(\.sourceAccount))
    let mappings = sourceAccounts.sorted().map { source -> YayoiAccountMapping in
      let target = accountMatch(source, availableAccounts: availableAccounts)
      return YayoiAccountMapping(
        sourceAccount: source,
        targetAccountID: target?.id,
        targetAccountName: target?.name
      )
    }
    let subMappings = makeSubAccountMappings(entries)
    let hasProblems =
      !quarantined.isEmpty || entries.contains { !$0.isBalanced }
      || mappings.contains { $0.targetAccountID == nil }
    return YayoiMigrationBatch(
      sourceFilename: filename,
      product: product,
      importedAt: importedAt,
      state: hasProblems ? .partiallyFailed : .preview,
      entries: entries,
      quarantinedRows: quarantined,
      accountMappings: mappings,
      subAccountMappings: subMappings
    )
  }

  private static func makeEntry(_ rows: [ParsedRow]) throws -> YayoiMigrationEntry {
    guard let first = rows.first, let last = rows.last else {
      throw YayoiMigrationError.noImportableRows
    }
    let date = try parseDate(first.columns[3])
    var lines: [YayoiMigrationLine] = []
    var descriptions: [String] = []
    for row in rows {
      let columns = row.columns
      if !columns[16].isEmpty { descriptions.append(columns[16]) }
      try appendLine(
        account: columns[4], subAccount: columns[5], taxText: columns[7],
        amountText: columns[8], side: .debit, to: &lines)
      try appendLine(
        account: columns[10], subAccount: columns[11], taxText: columns[13],
        amountText: columns[14], side: .credit, to: &lines)
    }
    let entry = YayoiMigrationEntry(
      date: date,
      description: descriptions.first ?? "弥生から移行",
      lines: lines,
      sourceRows: first.number...last.number
    )
    guard entry.isBalanced else {
      throw NSError(
        domain: "YayoiMigration", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "借方と貸方が一致しません"])
    }
    return entry
  }

  private static func openingBalancePreview(
    rows: [ParsedRow],
    filename: String,
    product: YayoiProduct,
    availableAccounts: [Account],
    importedAt: Date
  ) throws -> YayoiMigrationBatch {
    guard let first = rows.first, first.columns.count >= 6 else {
      throw YayoiMigrationError.noImportableRows
    }
    let openingDate = try parseDate(first.columns[0])
    var lines: [YayoiMigrationLine] = []
    var quarantined: [YayoiQuarantinedRow] = []
    for row in rows {
      guard row.columns.count >= 6 else {
        quarantined.append(
          YayoiQuarantinedRow(
            rowNumber: row.number,
            rawRow: row.raw,
            reason: "期首残高形式の6列を確認できません"
          ))
        continue
      }
      let account = row.columns[1]
      let side: PostingSide
      switch row.columns[2] {
      case "借方": side = .debit
      case "貸方": side = .credit
      default:
        quarantined.append(
          YayoiQuarantinedRow(
            rowNumber: row.number,
            rawRow: row.raw,
            reason: "貸借区分は「借方」または「貸方」で指定してください"
          ))
        continue
      }
      guard let amount = Int64(row.columns[5].replacingOccurrences(of: ",", with: "")), amount > 0,
        !account.isEmpty
      else {
        quarantined.append(
          YayoiQuarantinedRow(
            rowNumber: row.number,
            rawRow: row.raw,
            reason: "勘定科目または前期繰越残高が不正です"
          ))
        continue
      }
      lines.append(
        YayoiMigrationLine(
          sourceAccount: account,
          sourceSubAccount: row.columns[3].isEmpty ? nil : row.columns[3],
          side: side,
          amount: Money(yen: amount),
          tax: YayoiTaxMapping(rate: .outOfScope, deductibleBasisPoints: 0)
        ))
    }
    let entry = YayoiMigrationEntry(
      date: openingDate,
      description: "期首残高",
      lines: lines,
      sourceRows: first.number...(rows.last?.number ?? first.number)
    )
    if !entry.isBalanced {
      quarantined.append(
        YayoiQuarantinedRow(
          rowNumber: first.number,
          rawRow: "期首残高合計",
          reason: "期首残高の借方と貸方が一致しません"
        ))
    }
    let sourceAccounts = Set(lines.map(\.sourceAccount))
    let mappings = sourceAccounts.sorted().map { source -> YayoiAccountMapping in
      let target = accountMatch(source, availableAccounts: availableAccounts)
      return YayoiAccountMapping(
        sourceAccount: source,
        targetAccountID: target?.id,
        targetAccountName: target?.name
      )
    }
    let subMappings = makeSubAccountMappings([entry])
    let importable = entry.isBalanced ? [entry] : []
    return YayoiMigrationBatch(
      sourceFilename: filename,
      product: product,
      importedAt: importedAt,
      state: quarantined.isEmpty && mappings.allSatisfy({ $0.targetAccountID != nil })
        ? .preview : .partiallyFailed,
      entries: importable,
      quarantinedRows: quarantined,
      accountMappings: mappings,
      subAccountMappings: subMappings
    )
  }

  private static func makeSubAccountMappings(
    _ entries: [YayoiMigrationEntry]
  ) -> [YayoiSubAccountMapping] {
    let pairs = Set(
      entries.flatMap(\.lines).compactMap { line -> String? in
        line.sourceSubAccount.map { "\(line.sourceAccount)\u{1f}\($0)" }
      })
    return pairs.sorted().compactMap { value in
      let parts = value.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return nil }
      return YayoiSubAccountMapping(
        sourceAccount: parts[0],
        sourceSubAccount: parts[1],
        targetSubAccountName: parts[1]
      )
    }
  }

  private static func appendLine(
    account: String,
    subAccount: String,
    taxText: String,
    amountText: String,
    side: PostingSide,
    to lines: inout [YayoiMigrationLine]
  ) throws {
    let amount = Int64(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
    guard !account.isEmpty, amount > 0 else { return }
    guard let tax = YayoiTaxMapper.map(taxText) else {
      throw NSError(
        domain: "YayoiMigration", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "未対応の税区分: \(taxText)"])
    }
    lines.append(
      YayoiMigrationLine(
        sourceAccount: account,
        sourceSubAccount: subAccount.isEmpty ? nil : subAccount,
        side: side,
        amount: Money(yen: amount),
        tax: tax
      ))
  }

  private static func parseDate(_ value: String) throws -> Date {
    let formats = ["yyyy/MM/dd", "yyyy/M/d", "yyyyMMdd"]
    for format in formats {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "ja_JP")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    throw NSError(
      domain: "YayoiMigration", code: 3,
      userInfo: [NSLocalizedDescriptionKey: "取引日付を解釈できません: \(value)"])
  }

  private static func accountMatch(_ source: String, availableAccounts: [Account]) -> Account? {
    if let exact = availableAccounts.first(where: { $0.name == source }) { return exact }
    let aliases = [
      "普通預金": "普通預金",
      "現金": "現金",
      "売上高": "売上高",
      "売上": "売上高",
      "仕入高": "仕入高",
      "仕入": "仕入高",
      "消耗品費": "消耗品費",
      "旅費交通費": "旅費交通費",
      "通信費": "通信費",
      "事業主貸": "事業主貸",
      "事業主借": "事業主借",
    ]
    guard let targetName = aliases[source] else { return nil }
    return availableAccounts.first { $0.name == targetName }
  }

  private static func decode(_ data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    return String(data: data, encoding: .shiftJIS)
  }

  private static func parseRows(_ text: String) -> [ParsedRow] {
    text.components(separatedBy: .newlines).enumerated().compactMap { offset, raw in
      guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return ParsedRow(number: offset + 1, raw: raw, columns: parseColumns(raw))
    }
  }

  private static func parseColumns(_ row: String) -> [String] {
    var columns: [String] = []
    var field = ""
    var quoted = false
    var index = row.startIndex
    while index < row.endIndex {
      let character = row[index]
      let next = row.index(after: index)
      if character == "\"" {
        if quoted, next < row.endIndex, row[next] == "\"" {
          field.append("\"")
          index = row.index(after: next)
          continue
        }
        quoted.toggle()
      } else if character == ",", !quoted {
        columns.append(field)
        field = ""
      } else {
        field.append(character)
      }
      index = next
    }
    columns.append(field)
    return columns
  }
}
