import AppKit
import BlueprintDomain
import CoreGraphics
import Foundation

public struct InvoicePDFRecipient: Equatable, Sendable {
  public let name: String
  public let postalCode: String
  public let address: String

  public init(name: String, postalCode: String = "", address: String = "") {
    self.name = name
    self.postalCode = postalCode
    self.address = address
  }
}

public enum InvoicePDFRenderer {
  private static let pageSize = CGSize(width: 595, height: 842)

  public static func render(invoice: Invoice, recipient: InvoicePDFRecipient) throws -> Data {
    try invoice.validateDocumentFields()
    let total = try invoice.total()
    let summaries = try invoice.taxSummaries()
    let lineAmounts = try invoice.lines.map { try $0.netAmount() }
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
      let bitmapGraphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      throw BillingError.invalidAmount
    }
    bitmap.size = pageSize
    let context = bitmapGraphics.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(origin: .zero, size: pageSize))
    context.saveGState()
    context.translateBy(x: 0, y: pageSize.height)
    context.scaleBy(x: 1, y: -1)

    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    let title = attributes(size: 26, weight: .semibold)
    let heading = attributes(size: 11, weight: .semibold)
    let body = attributes(size: 10)
    let small = attributes(size: 8, color: .darkGray)
    let totalStyle = attributes(size: 17, weight: .bold)

    draw("請求書", at: CGPoint(x: 45, y: 42), width: 260, attributes: title)
    draw("No. \(invoice.number)", at: CGPoint(x: 392, y: 50), width: 155, attributes: body)
    draw(
      "発行日  \(dateString(invoice.issueDate))",
      at: CGPoint(x: 392, y: 70), width: 155, attributes: body)

    draw(recipient.name + " 御中", at: CGPoint(x: 45, y: 112), width: 295, attributes: heading)
    draw(
      [recipient.postalCode, recipient.address].filter { !$0.isEmpty }.joined(separator: "  "),
      at: CGPoint(x: 45, y: 136), width: 295, attributes: small)
    draw(invoice.issuerName, at: CGPoint(x: 360, y: 112), width: 190, attributes: heading)
    draw(invoice.issuerAddress, at: CGPoint(x: 360, y: 134), width: 190, attributes: small)
    if invoice.issuerRegistrationStatus == .qualified,
      let registration = invoice.issuerRegistrationNumber
    {
      draw("登録番号: \(registration)", at: CGPoint(x: 360, y: 152), width: 190, attributes: small)
    }

    rule(y: 186, context: context, color: .systemIndigo, width: 2)
    draw(invoice.subject, at: CGPoint(x: 45, y: 201), width: 360, attributes: heading)
    draw(
      "お支払期限  \(dateString(invoice.dueDate))",
      at: CGPoint(x: 392, y: 201), width: 160, attributes: body)

    draw("ご請求金額", at: CGPoint(x: 45, y: 238), width: 100, attributes: body)
    draw(yen(total), at: CGPoint(x: 150, y: 232), width: 190, attributes: totalStyle)

    let columns: [(String, CGFloat, CGFloat)] = [
      ("内容", 45, 300), ("数量", 350, 50), ("単価", 405, 70), ("金額", 480, 70),
    ]
    context.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
    context.fill(CGRect(x: 45, y: 286, width: 505, height: 28))
    for column in columns {
      draw(
        column.0, at: CGPoint(x: column.1 + 5, y: 294), width: column.2 - 10, attributes: heading)
    }

    var rowY: CGFloat = 320
    for (index, line) in invoice.lines.prefix(12).enumerated() {
      draw(line.description, at: CGPoint(x: 50, y: rowY + 7), width: 290, attributes: body)
      draw("\(line.quantity)", at: CGPoint(x: 355, y: rowY + 7), width: 40, attributes: body)
      draw(yen(line.unitPrice), at: CGPoint(x: 407, y: rowY + 7), width: 65, attributes: body)
      draw(yen(lineAmounts[index]), at: CGPoint(x: 482, y: rowY + 7), width: 65, attributes: body)
      rule(y: rowY + 31, context: context, color: .lightGray, width: 0.5)
      rowY += 32
    }

    let summaryY = max(rowY + 16, 560)
    draw("税率別内訳", at: CGPoint(x: 335, y: summaryY), width: 100, attributes: heading)
    var summaryRow = summaryY + 24
    for summary in summaries {
      draw(
        "\(taxLabel(summary.taxRate))対象  \(yen(summary.netAmount))",
        at: CGPoint(x: 335, y: summaryRow), width: 140, attributes: body)
      draw(
        "消費税  \(yen(summary.taxAmount))",
        at: CGPoint(x: 470, y: summaryRow), width: 80, attributes: body)
      summaryRow += 20
    }
    rule(y: summaryRow + 2, context: context, color: .darkGray, width: 1)
    draw("合計", at: CGPoint(x: 380, y: summaryRow + 13), width: 70, attributes: heading)
    draw(yen(total), at: CGPoint(x: 455, y: summaryRow + 10), width: 95, attributes: totalStyle)

    draw(
      invoice.issuerRegistrationStatus == .qualified
        ? "適格請求書の記載事項を確認して発行しています。"
        : "免税・未登録事業者として発行しています。",
      at: CGPoint(x: 45, y: 780), width: 505, attributes: small)
    draw("Blue-Print / ローカル生成", at: CGPoint(x: 420, y: 808), width: 130, attributes: small)
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()

    guard let pageImage = bitmap.cgImage else { throw BillingError.invalidAmount }
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw BillingError.invalidAmount
    }
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    let searchableSummary = [
      invoice.number,
      invoice.issuerRegistrationNumber ?? "unregistered",
      summaries.map { "\($0.taxRate.rawValue):\($0.netAmount.yen):\($0.taxAmount.yen)" }
        .joined(separator: ","),
      "total:\(total.yen)",
    ].joined(separator: " | ")
    let metadata: [CFString: Any] = [
      kCGPDFContextTitle: "Invoice \(invoice.number)",
      kCGPDFContextSubject: searchableSummary,
      kCGPDFContextCreator: "Blue-Print",
    ]
    guard
      let pdfContext = CGContext(
        consumer: consumer,
        mediaBox: &mediaBox,
        metadata as CFDictionary
      )
    else { throw BillingError.invalidAmount }
    pdfContext.beginPDFPage(nil)
    pdfContext.draw(pageImage, in: mediaBox)
    pdfContext.endPDFPage()
    pdfContext.closePDF()
    return data as Data
  }

  private static func attributes(
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .black
  ) -> [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: color,
    ]
  }

  private static func draw(
    _ value: String,
    at point: CGPoint,
    width: CGFloat,
    attributes: [NSAttributedString.Key: Any]
  ) {
    value.draw(
      in: CGRect(x: point.x, y: point.y, width: width, height: 30),
      withAttributes: attributes
    )
  }

  private static func rule(y: CGFloat, context: CGContext, color: NSColor, width: CGFloat) {
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.move(to: CGPoint(x: 45, y: y))
    context.addLine(to: CGPoint(x: 550, y: y))
    context.strokePath()
  }

  private static func yen(_ money: Money) -> String {
    "¥" + money.yen.formatted(.number.grouping(.automatic))
  }

  private static func dateString(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day())
  }

  private static func taxLabel(_ rate: TaxRate) -> String {
    switch rate {
    case .standard10: "10%"
    case .reduced8: "8%軽減"
    case .exempt: "非課税"
    case .outOfScope: "対象外"
    }
  }
}
