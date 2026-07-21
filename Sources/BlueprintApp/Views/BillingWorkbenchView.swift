import BlueprintBilling
import BlueprintDomain
import SwiftUI

private enum BillingMode: String, CaseIterable, Identifiable {
  case receivables = "請求・入金"
  case payables = "外注・支払"

  var id: String { rawValue }
}

private enum BillingFilter: String, CaseIterable, Identifiable {
  case all = "すべて"
  case open = "未消込"
  case overdue = "期限超過"
  case completed = "完了"

  var id: String { rawValue }
}

struct BillingWorkbenchView: View {
  @ObservedObject var model: AppModel
  @State private var mode: BillingMode = .receivables
  @State private var filter: BillingFilter = .all
  @State private var query = ""
  @State private var selectedInvoiceID: EntityID?
  @State private var selectedBillID: EntityID?
  @State private var showingCreate = false

  private var filteredInvoices: [Invoice] {
    model.invoices.filter { invoice in
      invoiceMatchesFilter(invoice)
        && (query.isEmpty
          || invoice.number.localizedCaseInsensitiveContains(query)
          || invoice.subject.localizedCaseInsensitiveContains(query)
          || counterpartyName(invoice.counterpartyID).localizedCaseInsensitiveContains(query))
    }
  }

  private var filteredBills: [VendorBill] {
    model.vendorBills.filter { bill in
      billMatchesFilter(bill)
        && (query.isEmpty
          || bill.referenceNumber.localizedCaseInsensitiveContains(query)
          || bill.description.localizedCaseInsensitiveContains(query)
          || counterpartyName(bill.vendorID).localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      summaryStrip
      Divider()
      HSplitView {
        listPane.frame(minWidth: 400, idealWidth: 470, maxWidth: 560)
        detailPane.frame(minWidth: 520)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showingCreate) {
      if mode == .receivables {
        InvoiceCreateSheet(model: model) { showingCreate = false }
      } else {
        VendorBillCreateSheet(model: model) { showingCreate = false }
      }
    }
    .onAppear {
      selectedInvoiceID = selectedInvoiceID ?? filteredInvoices.first?.id
      selectedBillID = selectedBillID ?? filteredBills.first?.id
    }
  }

  private var header: some View {
    VStack(spacing: 14) {
      HStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("請求・支払")
            .font(.system(size: 28, weight: .semibold))
          Text("発行から消込までを、証憑と仕訳につないで管理します。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("業務", selection: $mode) {
          ForEach(BillingMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        Button(
          mode == .receivables ? "請求書を作成" : "外注請求を登録",
          systemImage: "plus"
        ) {
          showingCreate = true
        }
        .buttonStyle(.borderedProminent)
      }
      HStack(spacing: 12) {
        Picker("状態", selection: $filter) {
          ForEach(BillingFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        TextField("取引先・番号・内容を検索", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 320)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var summaryStrip: some View {
    HStack(spacing: 0) {
      BillingMetric(
        title: mode == .receivables ? "未収残高" : "未払残高",
        value: yen(openBalance),
        systemImage: mode == .receivables ? "arrow.down.left" : "arrow.up.right",
        tint: .indigo
      )
      Divider().frame(height: 42)
      BillingMetric(
        title: "期限超過",
        value: "\(overdueCount)件",
        systemImage: "exclamationmark.circle",
        tint: overdueCount > 0 ? .orange : .secondary
      )
      Divider().frame(height: 42)
      BillingMetric(
        title: mode == .receivables ? "今月の請求" : "今月の外注",
        value: yen(currentMonthTotal),
        systemImage: "calendar",
        tint: .secondary
      )
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 13)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
  }

  @ViewBuilder
  private var listPane: some View {
    if mode == .receivables {
      List(filteredInvoices, selection: $selectedInvoiceID) { invoice in
        InvoiceListRow(invoice: invoice, counterparty: counterpartyName(invoice.counterpartyID))
          .tag(invoice.id)
      }
      .listStyle(.inset)
      .overlay { if filteredInvoices.isEmpty { emptyState } }
    } else {
      List(filteredBills, selection: $selectedBillID) { bill in
        VendorBillListRow(bill: bill, vendor: counterpartyName(bill.vendorID))
          .tag(bill.id)
      }
      .listStyle(.inset)
      .overlay { if filteredBills.isEmpty { emptyState } }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    if mode == .receivables,
      let invoice = model.invoices.first(where: { $0.id == selectedInvoiceID })
    {
      InvoiceDetailPane(
        model: model, invoice: invoice, customer: counterpartyName(invoice.counterpartyID))
    } else if mode == .payables,
      let bill = model.vendorBills.first(where: { $0.id == selectedBillID })
    {
      VendorBillDetailPane(model: model, bill: bill, vendor: counterpartyName(bill.vendorID))
    } else {
      emptyState
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(
      mode == .receivables ? "請求書はありません" : "外注請求はありません",
      systemImage: mode == .receivables ? "doc.text" : "tray",
      description: Text("右上のボタンから最初のデータを登録できます。")
    )
  }

  private var openBalance: Int64 {
    if mode == .receivables {
      return model.invoices.reduce(0) { $0 + ((try? $1.outstandingAmount().yen) ?? 0) }
    }
    return model.vendorBills.reduce(0) { $0 + ((try? $1.outstandingAmount().yen) ?? 0) }
  }

  private var overdueCount: Int {
    if mode == .receivables {
      return model.invoices.filter { $0.dueDate < Date() && isInvoiceOpen($0) }.count
    }
    return model.vendorBills.filter { $0.dueDate < Date() && isBillOpen($0) }.count
  }

  private var currentMonthTotal: Int64 {
    let calendar = Calendar.current
    if mode == .receivables {
      return model.invoices.filter {
        calendar.isDate($0.issueDate, equalTo: Date(), toGranularity: .month)
      }
      .reduce(0) { $0 + ((try? $1.total().yen) ?? 0) }
    }
    return model.vendorBills.filter {
      calendar.isDate($0.issueDate, equalTo: Date(), toGranularity: .month)
    }
    .reduce(0) { $0 + ((try? $1.grossAmount().yen) ?? 0) }
  }

  private func invoiceMatchesFilter(_ invoice: Invoice) -> Bool {
    switch filter {
    case .all: true
    case .open: isInvoiceOpen(invoice)
    case .overdue: invoice.dueDate < Date() && isInvoiceOpen(invoice)
    case .completed: invoice.status == .paid || invoice.status == .cancelled
    }
  }

  private func billMatchesFilter(_ bill: VendorBill) -> Bool {
    switch filter {
    case .all: true
    case .open: isBillOpen(bill)
    case .overdue: bill.dueDate < Date() && isBillOpen(bill)
    case .completed: bill.status == .paid || bill.status == .cancelled
    }
  }

  private func isInvoiceOpen(_ invoice: Invoice) -> Bool {
    [.issued, .partiallyPaid, .overdue].contains(invoice.status)
  }

  private func isBillOpen(_ bill: VendorBill) -> Bool {
    bill.status == .confirmed || bill.status == .partiallyPaid
  }

  private func counterpartyName(_ id: EntityID) -> String {
    model.counterparties.first(where: { $0.id == id })?.displayName ?? "取引先未設定"
  }
}

private struct BillingMetric: View {
  let title: String
  let value: String
  let systemImage: String
  let tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage).foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.headline.monospacedDigit())
      }
    }
    .frame(width: 190, alignment: .leading)
  }
}

private struct InvoiceListRow: View {
  let invoice: Invoice
  let counterparty: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(counterparty).font(.headline).lineLimit(1)
        Spacer()
        BillingStatusBadge(text: invoice.status.japaneseLabel, tint: invoice.status.badgeColor)
      }
      HStack {
        Text(invoice.number).font(.caption.monospaced()).foregroundStyle(.secondary)
        Text(invoice.subject).font(.caption).lineLimit(1)
        Spacer()
        Text(yen((try? invoice.total().yen) ?? 0)).font(.body.weight(.semibold).monospacedDigit())
      }
      Text(
        "期限 \(invoice.dueDate.formatted(date: .numeric, time: .omitted)) ・ 残高 \(yen((try? invoice.outstandingAmount().yen) ?? 0))"
      )
      .font(.caption2)
      .foregroundStyle(invoice.dueDate < Date() && invoice.status.isOpen ? .orange : .secondary)
    }
    .padding(.vertical, 6)
  }
}

private struct VendorBillListRow: View {
  let bill: VendorBill
  let vendor: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(vendor).font(.headline).lineLimit(1)
        Spacer()
        BillingStatusBadge(text: bill.status.japaneseLabel, tint: bill.status.badgeColor)
      }
      HStack {
        Text(bill.referenceNumber).font(.caption.monospaced()).foregroundStyle(.secondary)
        Text(bill.description).font(.caption).lineLimit(1)
        Spacer()
        Text(yen((try? bill.grossAmount().yen) ?? 0)).font(
          .body.weight(.semibold).monospacedDigit())
      }
      Text(
        "支払期限 \(bill.dueDate.formatted(date: .numeric, time: .omitted)) ・ 残高 \(yen((try? bill.outstandingAmount().yen) ?? 0))"
      )
      .font(.caption2)
      .foregroundStyle(bill.dueDate < Date() && bill.status.isOpen ? .orange : .secondary)
    }
    .padding(.vertical, 6)
  }
}

private struct BillingStatusBadge: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tint.opacity(0.11), in: Capsule())
  }
}

private struct InvoiceDetailPane: View {
  @ObservedObject var model: AppModel
  let invoice: Invoice
  let customer: String
  @State private var showingPayment = false
  @State private var showingCancel = false
  @State private var showingReissue = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(customer).font(.title2.weight(.semibold))
            Text("\(invoice.number)  ·  \(invoice.subject)").foregroundStyle(.secondary)
          }
          Spacer()
          BillingStatusBadge(text: invoice.status.japaneseLabel, tint: invoice.status.badgeColor)
        }
        HStack(spacing: 28) {
          AmountBlock(title: "請求額", value: (try? invoice.total().yen) ?? 0)
          AmountBlock(title: "入金済", value: invoice.paidAmount.yen)
          AmountBlock(
            title: "未収残高", value: (try? invoice.outstandingAmount().yen) ?? 0, emphasized: true)
        }
        Divider()
        sectionTitle("請求明細")
        ForEach(invoice.lines) { line in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(line.description)
              Text("\(line.quantity) × \(yen(line.unitPrice.yen)) ・ \(line.taxRate.japaneseLabel)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(yen((try? line.netAmount().yen) ?? 0)).monospacedDigit()
          }
          Divider()
        }
        sectionTitle("税率別集計")
        ForEach((try? invoice.taxSummaries()) ?? []) { summary in
          HStack {
            Text(summary.taxRate.japaneseLabel)
            Spacer()
            Text("対象 \(yen(summary.netAmount.yen))")
            Text("税 \(yen(summary.taxAmount.yen))").frame(width: 110, alignment: .trailing)
          }
          .font(.callout.monospacedDigit())
        }
        if !invoice.settlements.isEmpty {
          sectionTitle("入金履歴")
          ForEach(invoice.settlements) { settlement in
            HStack {
              Text(settlement.receivedAt.formatted(date: .numeric, time: .omitted))
              Spacer()
              Text(yen(settlement.appliedAmount.yen)).monospacedDigit()
            }
          }
        }
        HStack {
          Button("PDFを再発行", systemImage: "arrow.clockwise") { showingReissue = true }
          Button("取消", role: .destructive) { showingCancel = true }
            .disabled(!invoice.status.canCancel)
          Spacer()
          Button("入金を消込", systemImage: "checkmark") { showingPayment = true }
            .buttonStyle(.borderedProminent)
            .disabled(!invoice.status.isOpen)
        }
      }
      .padding(24)
    }
    .sheet(isPresented: $showingPayment) {
      InvoicePaymentSheet(model: model, invoice: invoice) { showingPayment = false }
    }
    .sheet(isPresented: $showingCancel) {
      ReasonSheet(title: "請求を取消", actionTitle: "取消する") { reason in
        model.cancelInvoice(invoice, reason: reason)
        showingCancel = false
      }
    }
    .sheet(isPresented: $showingReissue) {
      ReasonSheet(title: "PDFを再発行", actionTitle: "再発行する") { reason in
        model.reissueInvoice(invoice, reason: reason)
        showingReissue = false
      }
    }
  }
}

private struct VendorBillDetailPane: View {
  @ObservedObject var model: AppModel
  let bill: VendorBill
  let vendor: String
  @State private var showingPayment = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(vendor).font(.title2.weight(.semibold))
            Text("\(bill.referenceNumber)  ·  \(bill.description)").foregroundStyle(.secondary)
          }
          Spacer()
          BillingStatusBadge(text: bill.status.japaneseLabel, tint: bill.status.badgeColor)
        }
        HStack(spacing: 28) {
          AmountBlock(title: "請求額", value: (try? bill.grossAmount().yen) ?? 0)
          AmountBlock(title: "支払済", value: bill.paidAmount.yen)
          AmountBlock(
            title: "未払残高", value: (try? bill.outstandingAmount().yen) ?? 0, emphasized: true)
        }
        Divider()
        sectionTitle("支払条件")
        LabeledContent("支払期限", value: bill.dueDate.formatted(date: .long, time: .omitted))
        LabeledContent("インボイス", value: bill.invoiceStatus.japaneseLabel)
        LabeledContent(
          "源泉徴収", value: bill.withholdingEnabled ? yen(bill.withholdingTax.yen) : "使用しない（既定）")
        sectionTitle("明細")
        ForEach(bill.lines) { line in
          HStack {
            Text(line.description)
            Spacer()
            Text(yen((try? line.netAmount().yen) ?? 0)).monospacedDigit()
          }
          Divider()
        }
        HStack {
          Spacer()
          Button("支払を消込", systemImage: "checkmark") { showingPayment = true }
            .buttonStyle(.borderedProminent)
            .disabled(!bill.status.isOpen)
        }
      }
      .padding(24)
    }
    .sheet(isPresented: $showingPayment) {
      VendorPaymentSheet(model: model, bill: bill) { showingPayment = false }
    }
  }
}

private struct AmountBlock: View {
  let title: String
  let value: Int64
  var emphasized = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(yen(value))
        .font(emphasized ? .title2.weight(.semibold) : .title3.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(emphasized ? .indigo : .primary)
    }
  }
}

private struct InvoiceCreateSheet: View {
  @ObservedObject var model: AppModel
  let dismiss: () -> Void
  @State private var customer = ""
  @State private var number = ""
  @State private var issueDate = Date()
  @State private var dueDate =
    Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
  @State private var subject = ""
  @State private var lineDescription = "制作費"
  @State private var amount = 100_000
  @State private var taxRate: TaxRate = .standard10

  var body: some View {
    Form {
      TextField("顧客名", text: $customer)
      TextField("請求番号（空欄で自動採番）", text: $number)
      DatePicker("発行日", selection: $issueDate, displayedComponents: .date)
      DatePicker("支払期限", selection: $dueDate, displayedComponents: .date)
      TextField("件名", text: $subject)
      TextField("明細", text: $lineDescription)
      TextField("税抜金額", value: $amount, format: .number).monospacedDigit()
      Picker("税率", selection: $taxRate) {
        ForEach(TaxRate.allCases, id: \.self) { Text($0.japaneseLabel).tag($0) }
      }
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("発行して仕訳へ反映") {
          model.createInvoice(
            customerName: customer,
            number: number,
            issueDate: issueDate,
            dueDate: dueDate,
            subject: subject,
            lineDescription: lineDescription,
            netAmount: Int64(amount),
            taxRate: taxRate
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(customer.isEmpty || subject.isEmpty || amount <= 0)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct VendorBillCreateSheet: View {
  @ObservedObject var model: AppModel
  let dismiss: () -> Void
  @State private var vendor = ""
  @State private var reference = ""
  @State private var issueDate = Date()
  @State private var dueDate =
    Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
  @State private var description = ""
  @State private var amount = 80_000
  @State private var withholdingEnabled = false
  @State private var withholdingTax = 0

  var body: some View {
    Form {
      TextField("外注先", text: $vendor)
      TextField("請求書番号", text: $reference)
      DatePicker("請求日", selection: $issueDate, displayedComponents: .date)
      DatePicker("支払期限", selection: $dueDate, displayedComponents: .date)
      TextField("内容", text: $description)
      TextField("税抜金額", value: $amount, format: .number).monospacedDigit()
      Toggle("この取引だけ源泉徴収を使用", isOn: $withholdingEnabled)
      if withholdingEnabled {
        TextField("源泉税", value: $withholdingTax, format: .number).monospacedDigit()
      }
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("登録して仕訳へ反映") {
          model.createVendorBill(
            vendorName: vendor,
            referenceNumber: reference,
            issueDate: issueDate,
            dueDate: dueDate,
            description: description,
            netAmount: Int64(amount),
            withholdingEnabled: withholdingEnabled,
            withholdingTax: Int64(withholdingTax)
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(vendor.isEmpty || reference.isEmpty || description.isEmpty || amount <= 0)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct InvoicePaymentSheet: View {
  @ObservedObject var model: AppModel
  let invoice: Invoice
  let dismiss: () -> Void
  @State private var amount: Int
  @State private var bankFee = 0
  @State private var withholdingTax = 0
  @State private var discount = 0

  init(model: AppModel, invoice: Invoice, dismiss: @escaping () -> Void) {
    self.model = model
    self.invoice = invoice
    self.dismiss = dismiss
    _amount = State(initialValue: Int((try? invoice.outstandingAmount().yen) ?? 0))
  }

  var body: some View {
    Form {
      Text("入金消込").font(.title2.weight(.semibold))
      LabeledContent("未収残高", value: yen((try? invoice.outstandingAmount().yen) ?? 0))
      TextField("消込額", value: $amount, format: .number)
      TextField("振込手数料", value: $bankFee, format: .number)
      TextField("源泉徴収", value: $withholdingTax, format: .number)
      TextField("値引", value: $discount, format: .number)
      LabeledContent("普通預金への入金", value: yen(Int64(amount - bankFee - withholdingTax - discount)))
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("消込を確定") {
          model.recordInvoicePayment(
            invoice,
            appliedAmount: Int64(amount),
            bankFee: Int64(bankFee),
            withholdingTax: Int64(withholdingTax),
            discount: Int64(discount)
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(amount <= 0 || amount < bankFee + withholdingTax + discount)
      }
    }
    .padding(24)
    .frame(width: 460)
  }
}

private struct VendorPaymentSheet: View {
  @ObservedObject var model: AppModel
  let bill: VendorBill
  let dismiss: () -> Void
  @State private var amount: Int

  init(model: AppModel, bill: VendorBill, dismiss: @escaping () -> Void) {
    self.model = model
    self.bill = bill
    self.dismiss = dismiss
    _amount = State(initialValue: Int((try? bill.outstandingAmount().yen) ?? 0))
  }

  var body: some View {
    Form {
      Text("支払消込").font(.title2.weight(.semibold))
      LabeledContent("未払残高", value: yen((try? bill.outstandingAmount().yen) ?? 0))
      TextField("消込額", value: $amount, format: .number)
      if bill.withholdingEnabled {
        LabeledContent("源泉税", value: yen(min(bill.withholdingTax.yen, Int64(amount))))
      }
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("消込を確定") {
          model.recordVendorPayment(bill, appliedAmount: Int64(amount))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(amount <= 0)
      }
    }
    .padding(24)
    .frame(width: 430)
  }
}

private struct ReasonSheet: View {
  let title: String
  let actionTitle: String
  let action: (String) -> Void
  @State private var reason = ""

  var body: some View {
    Form {
      Text(title).font(.title2.weight(.semibold))
      TextField("理由", text: $reason, axis: .vertical)
      HStack {
        Spacer()
        Button(actionTitle) { action(reason) }
          .buttonStyle(.borderedProminent)
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}

private func sectionTitle(_ value: String) -> some View {
  Text(value).font(.headline)
}

private func yen(_ value: Int64) -> String {
  "¥" + value.formatted(.number.grouping(.automatic))
}

extension InvoiceStatus {
  fileprivate var isOpen: Bool { self == .issued || self == .partiallyPaid || self == .overdue }
  fileprivate var canCancel: Bool { (self == .issued || self == .overdue) }
  fileprivate var japaneseLabel: String {
    switch self {
    case .draft: "下書き"
    case .issued: "発行済"
    case .partiallyPaid: "一部入金"
    case .paid: "入金済"
    case .cancelled: "取消"
    case .overdue: "期限超過"
    case .corrected: "訂正済"
    case .refunded: "返還済"
    }
  }
  fileprivate var badgeColor: Color {
    switch self {
    case .paid: .green
    case .overdue: .orange
    case .cancelled, .refunded: .red
    case .partiallyPaid: .blue
    default: .indigo
    }
  }
}

extension VendorBillStatus {
  fileprivate var isOpen: Bool { self == .confirmed || self == .partiallyPaid }
  fileprivate var japaneseLabel: String {
    switch self {
    case .draft: "下書き"
    case .confirmed: "未払"
    case .partiallyPaid: "一部支払"
    case .paid: "支払済"
    case .cancelled: "取消"
    }
  }
  fileprivate var badgeColor: Color {
    switch self {
    case .paid: .green
    case .cancelled: .red
    case .partiallyPaid: .blue
    default: .indigo
    }
  }
}

extension TaxRate {
  fileprivate var japaneseLabel: String {
    switch self {
    case .standard10: "10%"
    case .reduced8: "8%（軽減）"
    case .exempt: "非課税"
    case .outOfScope: "対象外"
    }
  }
}

extension InvoiceRegistrationStatus {
  fileprivate var japaneseLabel: String {
    switch self {
    case .qualified: "適格"
    case .exemptOrUnregistered: "免税・未登録"
    case .unknown: "未確認"
    }
  }
}
