import AppKit
import BlueprintDomain
import CoreGraphics
import Foundation

public struct ReportVersionStamp: Equatable, Sendable {
  public let appVersion: String
  public let dataFormatVersion: Int
  public let taxRuleSetVersion: String
  public let formRuleSetVersion: String

  public init(
    appVersion: String = BlueprintVersions.app,
    dataFormatVersion: Int = BlueprintVersions.dataFormat,
    taxRuleSetVersion: String = BlueprintVersions.taxRuleSet,
    formRuleSetVersion: String = BlueprintVersions.formRuleSet
  ) {
    self.appVersion = appVersion
    self.dataFormatVersion = dataFormatVersion
    self.taxRuleSetVersion = taxRuleSetVersion
    self.formRuleSetVersion = formRuleSetVersion
  }

  public var compactDescription: String {
    "app=\(appVersion),data=\(dataFormatVersion),tax=\(taxRuleSetVersion),form=\(formRuleSetVersion)"
  }
}

public enum ReportExportError: Error, Equatable, Sendable {
  case renderingFailed
}

public enum ClosingReportExporter {
  private static let pageSize = CGSize(width: 595, height: 842)

  public static func journalCSV(
    entries: [JournalEntry],
    accounts: [Account],
    fiscalYear: FiscalYear,
    versions: ReportVersionStamp = ReportVersionStamp()
  ) -> Data {
    var rows = [
      ["Blue-Print仕訳帳", "年度", String(fiscalYear.calendarYear), versions.compactDescription],
      ["日付", "伝票ID", "区分", "摘要", "勘定科目コード", "勘定科目", "借方", "貸方", "税率", "インボイス区分"],
    ]
    let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, ($0.code, $0.name)) })
    for entry in entries.filter({ $0.status.countsInLedger }).sorted(by: journalSort) {
      for line in entry.lines {
        let account = names[line.accountID] ?? ("", "不明")
        rows.append([
          date(entry.transactionDate), entry.id.uuidString.lowercased(), entry.kind.rawValue,
          entry.description, account.0, account.1,
          line.side == .debit ? String(line.amount.yen) : "",
          line.side == .credit ? String(line.amount.yen) : "",
          line.taxRate.rawValue, line.invoiceStatus.rawValue,
        ])
      }
    }
    return csv(rows)
  }

  public static func financialStatementsCSV(
    profitAndLoss: ProfitAndLossReport,
    balanceSheet: BalanceSheetReport,
    fiscalYear: FiscalYear,
    versions: ReportVersionStamp = ReportVersionStamp()
  ) -> Data {
    var rows = [
      ["Blue-Print決算書", "年度", String(fiscalYear.calendarYear), versions.compactDescription],
      ["損益計算書"],
      ["区分", "コード", "科目", "金額"],
    ]
    rows += profitAndLoss.revenue.map {
      ["収益", $0.accountCode, $0.accountName, String($0.amount.yen)]
    }
    rows += profitAndLoss.expenses.map {
      ["費用", $0.accountCode, $0.accountName, String($0.amount.yen)]
    }
    rows += [["当期利益", "", "", String(profitAndLoss.profit.yen)], ["貸借対照表"]]
    rows += [["区分", "コード", "科目", "金額"]]
    rows += balanceSheet.assets.map {
      ["資産", $0.accountCode, $0.accountName, String($0.amount.yen)]
    }
    rows += balanceSheet.liabilities.map {
      ["負債", $0.accountCode, $0.accountName, String($0.amount.yen)]
    }
    rows += balanceSheet.equity.map {
      ["資本", $0.accountCode, $0.accountName, String($0.amount.yen)]
    }
    rows += [
      ["資産合計", "", "", String(balanceSheet.totalAssets.yen)],
      ["負債・資本・当期利益合計", "", "", String(balanceSheet.totalLiabilitiesAndEquity.yen)],
    ]
    return csv(rows)
  }

  public static func fixedAssetLedgerCSV(
    assets: [FixedAsset],
    through calendarYear: Int,
    versions: ReportVersionStamp = ReportVersionStamp()
  ) throws -> Data {
    var rows = [
      ["Blue-Print固定資産台帳", "年度", String(calendarYear), versions.compactDescription],
      ["資産コード", "資産名", "取得価額", "償却方法", "年", "期首簿価", "償却額", "事業分", "期末簿価"],
    ]
    for asset in assets {
      for record in try asset.depreciationSchedule(through: calendarYear) {
        rows.append([
          asset.code, asset.name, String(asset.acquisitionCost.yen), asset.method.rawValue,
          String(record.calendarYear), String(record.openingBookValue.yen),
          String(record.accountingDepreciation.yen), String(record.businessDepreciation.yen),
          String(record.closingBookValue.yen),
        ])
      }
    }
    return csv(rows)
  }

  public static func financialStatementsPDF(
    profitAndLoss: ProfitAndLossReport,
    balanceSheet: BalanceSheetReport,
    profileName: String,
    fiscalYear: FiscalYear,
    versions: ReportVersionStamp = ReportVersionStamp()
  ) throws -> Data {
    let profitPage = try rasterizedPage { context in
      drawHeader("損益計算書", profileName: profileName, fiscalYear: fiscalYear, context: context)
      var y: CGFloat = 130
      drawSection("収益", y: &y, context: context)
      drawRows(profitAndLoss.revenue, y: &y, context: context)
      drawTotal("収益合計", profitAndLoss.totalRevenue, y: &y, context: context)
      y += 18
      drawSection("費用", y: &y, context: context)
      drawRows(profitAndLoss.expenses, y: &y, context: context)
      drawTotal("費用合計", profitAndLoss.totalExpenses, y: &y, context: context)
      y += 22
      drawTotal("当期利益", profitAndLoss.profit, y: &y, emphasized: true, context: context)
      drawFooter(versions, context: context)
    }
    let balancePage = try rasterizedPage { context in
      drawHeader("貸借対照表", profileName: profileName, fiscalYear: fiscalYear, context: context)
      var y: CGFloat = 130
      drawSection("資産", y: &y, context: context)
      drawRows(balanceSheet.assets, y: &y, context: context)
      drawTotal("資産合計", balanceSheet.totalAssets, y: &y, context: context)
      y += 18
      drawSection("負債", y: &y, context: context)
      drawRows(balanceSheet.liabilities, y: &y, context: context)
      drawSection("資本", y: &y, context: context)
      drawRows(balanceSheet.equity, y: &y, context: context)
      drawTotal("当期利益", balanceSheet.currentProfit, y: &y, context: context)
      drawTotal(
        "負債・資本合計",
        balanceSheet.totalLiabilitiesAndEquity,
        y: &y,
        emphasized: true,
        context: context
      )
      drawFooter(versions, context: context)
    }
    return try pdf(
      pages: [profitPage, balancePage],
      title: "Blue-Print \(fiscalYear.calendarYear)年度 決算書",
      subject: versions.compactDescription
    )
  }

  public static func journalPDF(
    entries: [JournalEntry],
    accounts: [Account],
    profileName: String,
    fiscalYear: FiscalYear,
    versions: ReportVersionStamp = ReportVersionStamp()
  ) throws -> Data {
    let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
    let chunks = stride(from: 0, to: entries.count, by: 22).map {
      Array(entries[$0..<min($0 + 22, entries.count)])
    }
    let pages = try (chunks.isEmpty ? [[]] : chunks).map { chunk in
      try rasterizedPage { context in
        drawHeader("仕訳帳", profileName: profileName, fiscalYear: fiscalYear, context: context)
        var y: CGFloat = 130
        for entry in chunk {
          drawText(date(entry.transactionDate), x: 45, y: y, width: 70, size: 9, context: context)
          drawText(entry.description, x: 120, y: y, width: 180, size: 9, context: context)
          let debit = entry.lines.filter { $0.side == .debit }
          let credit = entry.lines.filter { $0.side == .credit }
          drawText(
            debit.map { accountNames[$0.accountID] ?? "不明" }.joined(separator: "/"),
            x: 305,
            y: y,
            width: 90,
            size: 8,
            context: context
          )
          drawText(
            yen(debit.reduce(0) { $0 + $1.amount.yen }),
            x: 397,
            y: y,
            width: 65,
            size: 9,
            context: context
          )
          drawText(
            credit.map { accountNames[$0.accountID] ?? "不明" }.joined(separator: "/"),
            x: 465,
            y: y,
            width: 85,
            size: 8,
            context: context
          )
          context.setStrokeColor(NSColor.separatorColor.cgColor)
          context.move(to: CGPoint(x: 45, y: y + 22))
          context.addLine(to: CGPoint(x: 550, y: y + 22))
          context.strokePath()
          y += 28
        }
        drawFooter(versions, context: context)
      }
    }
    return try pdf(
      pages: pages,
      title: "Blue-Print \(fiscalYear.calendarYear)年度 仕訳帳",
      subject: versions.compactDescription
    )
  }

  private static func csv(_ rows: [[String]]) -> Data {
    let body = rows.map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n")
    return Data(("\u{FEFF}" + body + "\r\n").utf8)
  }

  private static func escapeCSV(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func rasterizedPage(
    draw: (CGContext) -> Void
  ) throws -> CGImage {
    let scale = 2
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pageSize.width) * scale,
        pixelsHigh: Int(pageSize.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw ReportExportError.renderingFailed }
    bitmap.size = pageSize
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(origin: .zero, size: pageSize))
    context.saveGState()
    context.translateBy(x: 0, y: pageSize.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
    guard let image = bitmap.cgImage else { throw ReportExportError.renderingFailed }
    return image
  }

  private static func pdf(pages: [CGImage], title: String, subject: String) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw ReportExportError.renderingFailed
    }
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    let info: [CFString: Any] = [
      kCGPDFContextTitle: title,
      kCGPDFContextSubject: subject,
      kCGPDFContextCreator: "Blue-Print",
    ]
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
    else { throw ReportExportError.renderingFailed }
    for page in pages {
      context.beginPDFPage(nil)
      context.draw(page, in: mediaBox)
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  private static func drawHeader(
    _ title: String,
    profileName: String,
    fiscalYear: FiscalYear,
    context: CGContext
  ) {
    drawText(title, x: 45, y: 42, width: 300, size: 25, weight: .semibold, context: context)
    drawText(profileName, x: 360, y: 48, width: 190, size: 11, weight: .semibold, context: context)
    drawText("\(fiscalYear.calendarYear)年度", x: 360, y: 70, width: 190, size: 9, context: context)
    context.setStrokeColor(NSColor.systemIndigo.cgColor)
    context.setLineWidth(2)
    context.move(to: CGPoint(x: 45, y: 105))
    context.addLine(to: CGPoint(x: 550, y: 105))
    context.strokePath()
  }

  private static func drawSection(_ title: String, y: inout CGFloat, context: CGContext) {
    context.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
    context.fill(CGRect(x: 45, y: y, width: 505, height: 26))
    drawText(title, x: 52, y: y + 6, width: 220, size: 10, weight: .semibold, context: context)
    y += 32
  }

  private static func drawRows(
    _ rows: [ReportAccountAmount],
    y: inout CGFloat,
    context: CGContext
  ) {
    for row in rows.prefix(17) {
      drawText(row.accountCode, x: 52, y: y, width: 55, size: 9, context: context)
      drawText(row.accountName, x: 112, y: y, width: 280, size: 9, context: context)
      drawText(yen(row.amount.yen), x: 420, y: y, width: 125, size: 9, context: context)
      y += 23
    }
  }

  private static func drawTotal(
    _ title: String,
    _ amount: Money,
    y: inout CGFloat,
    emphasized: Bool = false,
    context: CGContext
  ) {
    context.setStrokeColor(NSColor.darkGray.cgColor)
    context.move(to: CGPoint(x: 330, y: y))
    context.addLine(to: CGPoint(x: 550, y: y))
    context.strokePath()
    drawText(title, x: 335, y: y + 8, width: 100, size: 10, weight: .semibold, context: context)
    drawText(
      yen(amount.yen),
      x: 440,
      y: y + 5,
      width: 105,
      size: emphasized ? 14 : 11,
      weight: emphasized ? .bold : .semibold,
      context: context
    )
    y += 35
  }

  private static func drawFooter(_ versions: ReportVersionStamp, context: CGContext) {
    drawText(
      "Blue-Print \(versions.compactDescription)",
      x: 45,
      y: 810,
      width: 505,
      size: 7,
      color: .darkGray,
      context: context
    )
  }

  private static func drawText(
    _ value: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .black,
    context: CGContext
  ) {
    value.draw(
      in: CGRect(x: x, y: y, width: width, height: 24),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
      ]
    )
  }

  private static func date(_ value: Date) -> String {
    value.formatted(.dateTime.year().month().day())
  }

  private static func yen(_ value: Int64) -> String {
    "¥" + value.formatted(.number.grouping(.automatic))
  }

  private static func journalSort(_ lhs: JournalEntry, _ rhs: JournalEntry) -> Bool {
    lhs.transactionDate == rhs.transactionDate
      ? lhs.metadata.createdAt < rhs.metadata.createdAt
      : lhs.transactionDate < rhs.transactionDate
  }
}
