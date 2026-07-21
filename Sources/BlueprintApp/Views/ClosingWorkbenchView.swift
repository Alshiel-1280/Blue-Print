import BlueprintClosing
import BlueprintDomain
import SwiftUI
import UniformTypeIdentifiers

private enum ClosingMode: String, CaseIterable, Identifiable {
  case tasks = "月次・決算"
  case reports = "レポート"
  case assets = "固定資産"

  var id: String { rawValue }
}

private enum ReportScope: String, CaseIterable, Identifiable {
  case annual = "年次"
  case monthly = "月次"

  var id: String { rawValue }
}

struct ClosingWorkbenchView: View {
  @ObservedObject var model: AppModel
  @State private var mode: ClosingMode = .tasks
  @State private var selectedCheckID: String?
  @State private var showingAsset = false
  @State private var showingInventory = false
  @State private var showingAllocation = false
  @State private var exportDocument: BinaryExportDocument?
  @State private var exportType: UTType = .pdf
  @State private var exportFilename = ""
  @State private var showingExporter = false
  @State private var reportScope: ReportScope = .annual
  @State private var reportDate = Date()

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      switch mode {
      case .tasks: taskWorkspace
      case .reports: reportWorkspace
      case .assets: assetWorkspace
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showingAsset) {
      FixedAssetCreateSheet(model: model) { showingAsset = false }
    }
    .sheet(isPresented: $showingInventory) {
      InventoryClosingSheet(model: model) { showingInventory = false }
    }
    .sheet(isPresented: $showingAllocation) {
      HouseholdAllocationSheet(model: model) { showingAllocation = false }
    }
    .fileExporter(
      isPresented: $showingExporter,
      document: exportDocument,
      contentType: exportType,
      defaultFilename: exportFilename
    ) { _ in }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("決算・レポート")
          .font(.system(size: 28, weight: .semibold))
        Text("月次の確認から年度締め、帳簿出力までを順番に進めます。")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("表示", selection: $mode) {
        ForEach(ClosingMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .frame(width: 320)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var taskWorkspace: some View {
    VStack(spacing: 0) {
      progressHeader
      Divider()
      HSplitView {
        List(taskRows, selection: $selectedCheckID) { row in
          ClosingTaskRow(row: row).tag(row.id)
        }
        .listStyle(.inset)
        .frame(minWidth: 520, idealWidth: 650)
        taskDetail.frame(minWidth: 420)
      }
    }
  }

  private var progressHeader: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(model.fiscalYear?.calendarYear ?? 0)年度の決算")
          .font(.headline)
        Text("年度締め前チェック")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: progress)
        .frame(maxWidth: 420)
      Text("\(resolvedCount) / \(taskRows.count) 完了")
        .font(.headline.monospacedDigit())
      Spacer()
      if let warning = model.closingChecklist.finalizeWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
          .frame(maxWidth: 300, alignment: .trailing)
      } else {
        Label("年度確定の準備完了", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
  }

  private var taskDetail: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let row = taskRows.first(where: { $0.id == selectedCheckID }) ?? taskRows.first {
        HStack {
          Image(systemName: row.isResolved ? "checkmark.circle.fill" : row.systemImage)
            .font(.title2)
            .foregroundStyle(row.isResolved ? .green : row.tint)
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.title2.weight(.semibold))
            Text(row.detail).foregroundStyle(.secondary)
          }
        }
        Divider()
        Text(row.guidance).font(.body)
        if row.id == "inventory" {
          Button("棚卸金額を入力", systemImage: "shippingbox") { showingInventory = true }
            .buttonStyle(.borderedProminent)
        } else if row.id == "allocation" {
          Button("家事按分を登録", systemImage: "percent") { showingAllocation = true }
            .buttonStyle(.borderedProminent)
        } else if row.id == "assets" {
          Button("固定資産台帳を開く", systemImage: "desktopcomputer") { mode = .assets }
            .buttonStyle(.borderedProminent)
        } else if row.id == "reports" {
          Button("決算書を確認", systemImage: "doc.text") { mode = .reports }
            .buttonStyle(.borderedProminent)
        }
        Spacer()
        HStack {
          Text(row.isResolved ? "確認済み" : "対応が必要です")
            .font(.caption.weight(.semibold))
            .foregroundStyle(row.isResolved ? .green : row.tint)
          Spacer()
          Text("更新: ローカルデータ")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(24)
  }

  private var reportWorkspace: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Picker("集計期間", selection: $reportScope) {
            ForEach(ReportScope.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .frame(width: 150)
          if reportScope == .monthly {
            DatePicker("対象月", selection: $reportDate, displayedComponents: .date)
              .datePickerStyle(.compact)
          }
          Spacer()
          Text(reportPeriodLabel).font(.subheadline.weight(.semibold))
        }
        HStack {
          reportSummary(
            "売上高",
            value: selectedProfitReport?.totalRevenue.yen ?? 0,
            tint: .indigo
          )
          reportSummary(
            "経費",
            value: selectedProfitReport?.totalExpenses.yen ?? 0,
            tint: .orange
          )
          reportSummary(
            "当期利益",
            value: selectedProfitReport?.profit.yen ?? 0,
            tint: .green
          )
          reportSummary(
            "資産合計",
            value: selectedBalanceReport?.totalAssets.yen ?? 0,
            tint: .secondary
          )
        }
        Divider()
        HStack(alignment: .top, spacing: 28) {
          reportColumn("損益計算書", rows: reportProfitRows)
          reportColumn("貸借対照表", rows: reportBalanceRows)
        }
        Divider()
        Text("税区分・インボイス区分別集計").font(.headline)
        ForEach(model.taxClassificationBalances) { balance in
          HStack {
            Text(balance.taxRate.closingJapaneseLabel)
            Text(balance.invoiceStatus.closingJapaneseLabel).foregroundStyle(.secondary)
            Text("控除 \(balance.deductibleBasisPoints / 100)%").foregroundStyle(.secondary)
            Spacer()
            Text(yen(balance.taxableAmount.yen)).monospacedDigit()
          }
          Divider()
        }
        Divider()
        Text("売掛・未払年齢表").font(.headline)
        HStack(alignment: .top, spacing: 28) {
          agingColumn("売掛金", rows: model.receivableAging)
          agingColumn("未払金", rows: model.payableAging)
        }
        HStack {
          Button("決算書 PDF", systemImage: "doc.richtext") {
            startExport(data: model.financialStatementsPDF(), type: .pdf, name: "決算書")
          }
          Button("決算書 CSV", systemImage: "tablecells") {
            startExport(
              data: model.financialStatementsCSV(), type: .commaSeparatedText, name: "決算書")
          }
          Button("仕訳帳 PDF", systemImage: "book.closed") {
            startExport(data: model.journalExportPDF(), type: .pdf, name: "仕訳帳")
          }
          Button("仕訳帳 CSV", systemImage: "tablecells") {
            startExport(data: model.journalExportCSV(), type: .commaSeparatedText, name: "仕訳帳")
          }
          Spacer()
          Text("app \(BlueprintVersions.app)・税ルール \(BlueprintVersions.taxRuleSet)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(24)
    }
  }

  private var assetWorkspace: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("固定資産台帳").font(.headline)
          Text("取得価額、償却方法、事業割合、年度別簿価を管理します。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("固定資産を登録", systemImage: "plus") { showingAsset = true }
          .buttonStyle(.borderedProminent)
        Button("台帳CSV") {
          startExport(data: model.fixedAssetLedgerCSV(), type: .commaSeparatedText, name: "固定資産台帳")
        }
      }
      .padding(20)
      Divider()
      Table(model.fixedAssets) {
        TableColumn("コード") { Text($0.code).monospaced() }.width(90)
        TableColumn("資産名") { Text($0.name) }.width(min: 180)
        TableColumn("取得価額") { Text(yen($0.acquisitionCost.yen)).monospacedDigit() }.width(110)
        TableColumn("償却方法") { Text($0.method.japaneseLabel) }.width(100)
        TableColumn("事業割合") { Text("\($0.businessUseBasisPoints / 100)%") }.width(80)
        TableColumn("当年償却") { asset in
          Text(
            yen(
              (try? asset.depreciationSchedule(through: model.fiscalYear?.calendarYear ?? 0).last?
                .businessDepreciation.yen) ?? 0)
          )
          .monospacedDigit()
        }.width(110)
        TableColumn("操作") { asset in
          Button("償却仕訳を作成") { model.postDepreciation(asset) }
            .disabled(hasDepreciationJournal(asset))
        }.width(130)
      }
      .overlay {
        if model.fixedAssets.isEmpty {
          ContentUnavailableView(
            "固定資産はありません",
            systemImage: "desktopcomputer",
            description: Text("取得した固定資産を登録すると年度別償却を計算できます。")
          )
        }
      }
    }
  }

  private var taskRows: [ClosingTask] {
    let databaseRows = model.closingChecklist.items.map { item in
      ClosingTask(
        id: item.id,
        title: item.title,
        detail: item.detail,
        guidance: guidance(for: item.id),
        isResolved: item.isResolved,
        systemImage: item.severity == .blocking ? "exclamationmark.circle" : "info.circle",
        tint: item.severity == .blocking ? .orange : .blue
      )
    }
    let depreciationResolved = model.fixedAssets.allSatisfy(hasDepreciationJournal)
    return databaseRows + [
      ClosingTask(
        id: "allocation",
        title: "家事按分を確認",
        detail: "通信費などの事業割合を反映",
        guidance: "家事利用を含む経費は、根拠と割合を記録して事業主貸へ振り替えます。",
        isResolved: model.journalEntries.contains {
          $0.kind == .closing && $0.description.hasPrefix("家事按分")
        },
        systemImage: "percent",
        tint: .blue
      ),
      ClosingTask(
        id: "assets",
        title: "固定資産を償却",
        detail: "登録 \(model.fixedAssets.count)件",
        guidance: "供用月、償却方法、事業割合を確認し、当年の減価償却仕訳を作成します。",
        isResolved: depreciationResolved,
        systemImage: "desktopcomputer",
        tint: .blue
      ),
      ClosingTask(
        id: "reports",
        title: "決算書の整合を確認",
        detail: model.annualBalanceSheet?.balances == true ? "貸借一致" : "貸借差額あり",
        guidance: "損益計算書の当期利益と貸借対照表の増減が一致しているか確認します。",
        isResolved: model.annualBalanceSheet?.balances == true,
        systemImage: "doc.text.magnifyingglass",
        tint: .blue
      ),
    ]
  }

  private var progress: Double {
    guard !taskRows.isEmpty else { return 0 }
    return Double(resolvedCount) / Double(taskRows.count)
  }

  private var resolvedCount: Int { taskRows.filter(\.isResolved).count }

  private var reportProfitRows: [(String, Int64)] {
    guard let report = selectedProfitReport else { return [] }
    return report.revenue.map { ($0.accountName, $0.amount.yen) }
      + report.expenses.map { ($0.accountName, $0.amount.yen) }
      + [("当期利益", report.profit.yen)]
  }

  private var reportBalanceRows: [(String, Int64)] {
    guard let report = selectedBalanceReport else { return [] }
    return report.assets.map { ($0.accountName, $0.amount.yen) }
      + report.liabilities.map { ($0.accountName, $0.amount.yen) }
      + report.equity.map { ($0.accountName, $0.amount.yen) }
      + [("当期利益", report.currentProfit.yen)]
  }

  private var selectedProfitReport: ProfitAndLossReport? {
    guard reportScope == .monthly else { return model.annualProfitAndLoss }
    let calendar = Calendar(identifier: .gregorian)
    guard let interval = calendar.dateInterval(of: .month, for: reportDate) else { return nil }
    return model.profitAndLoss(
      period: interval.start...interval.end.addingTimeInterval(-1)
    )
  }

  private var selectedBalanceReport: BalanceSheetReport? {
    guard reportScope == .monthly else { return model.annualBalanceSheet }
    let calendar = Calendar(identifier: .gregorian)
    guard let interval = calendar.dateInterval(of: .month, for: reportDate) else { return nil }
    return model.balanceSheet(asOf: interval.end.addingTimeInterval(-1))
  }

  private var reportPeriodLabel: String {
    if reportScope == .annual { return "\(model.fiscalYear?.calendarYear ?? 0)年度" }
    return reportDate.formatted(.dateTime.year().month())
  }

  private func reportSummary(_ title: String, value: Int64, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(yen(value)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func reportColumn(_ title: String, rows: [(String, Int64)]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack {
          Text(row.0)
          Spacer()
          Text(yen(row.1)).monospacedDigit()
        }
        Divider()
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func agingColumn(_ title: String, rows: [AgingAmount]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.subheadline.weight(.semibold))
      if rows.isEmpty {
        Text("残高なし").foregroundStyle(.secondary)
      } else {
        ForEach(rows) { row in
          HStack {
            Text(row.counterpartyName)
            Text(row.bucket.japaneseLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(yen(row.amount.yen)).monospacedDigit()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func guidance(for id: String) -> String {
    switch id {
    case "evidence": "確認待ちの証憑と明細を処理し、すべて仕訳へ反映または対象外にします。"
    case "journals": "下書き・確認待ちの仕訳を確定し、決算集計の対象を揃えます。"
    case "settlements": "期限超過の売掛・未払は、残高の妥当性と回収・支払予定を確認します。"
    case "inventory": "期首棚卸、当期仕入、期末棚卸を入力して売上原価を確定します。"
    default: "内容を確認し、未解決項目を完了してください。"
    }
  }

  private func hasDepreciationJournal(_ asset: FixedAsset) -> Bool {
    model.journalEntries.contains {
      $0.kind == .closing && $0.description == "減価償却 \(asset.code) \(asset.name)"
    }
  }

  private func startExport(data: Data?, type: UTType, name: String) {
    guard let data else { return }
    exportDocument = BinaryExportDocument(data: data)
    exportType = type
    exportFilename = "\(model.fiscalYear?.calendarYear ?? 0)年度-\(name)"
    showingExporter = true
  }
}

private struct ClosingTask: Identifiable {
  let id: String
  let title: String
  let detail: String
  let guidance: String
  let isResolved: Bool
  let systemImage: String
  let tint: Color
}

private struct ClosingTaskRow: View {
  let row: ClosingTask

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: row.isResolved ? "checkmark.circle.fill" : row.systemImage)
        .foregroundStyle(row.isResolved ? .green : row.tint)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(row.title).font(.headline)
        Text(row.detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(row.isResolved ? "完了" : "要確認")
        .font(.caption.weight(.semibold))
        .foregroundStyle(row.isResolved ? .green : row.tint)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 8)
  }
}

private struct FixedAssetCreateSheet: View {
  @ObservedObject var model: AppModel
  let dismiss: () -> Void
  @State private var code = ""
  @State private var name = ""
  @State private var category = "工具器具備品"
  @State private var acquisitionDate = Date()
  @State private var serviceDate = Date()
  @State private var cost = 300_000
  @State private var usefulLife = 5
  @State private var method: DepreciationMethod = .straightLine
  @State private var businessPercent = 100
  @State private var assetAccountID: EntityID?
  @State private var expenseAccountID: EntityID?
  @State private var accumulatedAccountID: EntityID?

  var body: some View {
    Form {
      TextField("資産コード", text: $code)
      TextField("資産名", text: $name)
      TextField("種類", text: $category)
      DatePicker("取得日", selection: $acquisitionDate, displayedComponents: .date)
      DatePicker("供用開始日", selection: $serviceDate, displayedComponents: .date)
      TextField("取得価額", value: $cost, format: .number)
      Stepper("耐用年数 \(usefulLife)年", value: $usefulLife, in: 1...50)
      Picker("償却方法", selection: $method) {
        ForEach(DepreciationMethod.allCases, id: \.self) { Text($0.japaneseLabel).tag($0) }
      }
      Stepper("事業割合 \(businessPercent)%", value: $businessPercent, in: 0...100)
      accountPicker("資産科目", selection: $assetAccountID)
      accountPicker("減価償却費", selection: $expenseAccountID)
      accountPicker("減価償却累計額", selection: $accumulatedAccountID)
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("登録") {
          guard let assetAccountID, let expenseAccountID, let accumulatedAccountID else { return }
          model.saveFixedAsset(
            code: code,
            name: name,
            category: category,
            acquisitionDate: acquisitionDate,
            serviceDate: serviceDate,
            cost: Int64(cost),
            usefulLifeYears: usefulLife,
            method: method,
            businessUseBasisPoints: businessPercent * 100,
            assetAccountID: assetAccountID,
            depreciationExpenseAccountID: expenseAccountID,
            accumulatedDepreciationAccountID: accumulatedAccountID
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          code.isEmpty || name.isEmpty || assetAccountID == nil || expenseAccountID == nil
            || accumulatedAccountID == nil)
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear {
      assetAccountID = model.accounts.first { $0.code == "1500" }?.id
      expenseAccountID = model.accounts.first { $0.code == "5600" }?.id
      accumulatedAccountID = model.accounts.first { $0.code == "1590" }?.id
    }
  }

  private func accountPicker(_ title: String, selection: Binding<EntityID?>) -> some View {
    Picker(title, selection: selection) {
      Text("選択してください").tag(EntityID?.none)
      ForEach(model.accounts.filter(\.isActive)) { account in
        Text("\(account.code) \(account.name)").tag(EntityID?.some(account.id))
      }
    }
  }
}

private struct InventoryClosingSheet: View {
  @ObservedObject var model: AppModel
  let dismiss: () -> Void
  @State private var opening = 0
  @State private var purchases = 0
  @State private var closing = 0

  var body: some View {
    Form {
      Text("期末棚卸").font(.title2.weight(.semibold))
      TextField("期首棚卸高", value: $opening, format: .number)
      TextField("当期仕入高", value: $purchases, format: .number)
      TextField("期末棚卸高", value: $closing, format: .number)
      LabeledContent("売上原価", value: yen(Int64(opening + purchases - closing)))
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("保存") {
          model.saveInventory(
            opening: Int64(opening), purchases: Int64(purchases), closing: Int64(closing))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}

private struct HouseholdAllocationSheet: View {
  @ObservedObject var model: AppModel
  let dismiss: () -> Void
  @State private var name = "通信費"
  @State private var expenseAccountID: EntityID?
  @State private var ownerDrawingsAccountID: EntityID?
  @State private var personalPercent = 30
  @State private var rationale = "利用時間"

  var body: some View {
    Form {
      Text("家事按分").font(.title2.weight(.semibold))
      TextField("ルール名", text: $name)
      Picker("対象経費", selection: $expenseAccountID) {
        Text("選択してください").tag(EntityID?.none)
        ForEach(model.accounts.filter { $0.category == .expense && $0.isActive }) {
          Text("\($0.code) \($0.name)").tag(EntityID?.some($0.id))
        }
      }
      Stepper("家事割合 \(personalPercent)%", value: $personalPercent, in: 0...100)
      TextField("按分根拠", text: $rationale)
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("保存して決算仕訳を作成") {
          guard let expenseAccountID, let ownerDrawingsAccountID else { return }
          model.saveHouseholdRule(
            name: name,
            expenseAccountID: expenseAccountID,
            ownerDrawingsAccountID: ownerDrawingsAccountID,
            personalBasisPoints: personalPercent * 100,
            rationale: rationale
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(expenseAccountID == nil || ownerDrawingsAccountID == nil)
      }
    }
    .padding(24)
    .frame(width: 480)
    .onAppear {
      expenseAccountID = model.accounts.first { $0.code == "5300" }?.id
      ownerDrawingsAccountID = model.accounts.first { $0.code == "3100" }?.id
    }
  }
}

private struct BinaryExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.pdf, .commaSeparatedText] }
  let data: Data

  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private func yen(_ value: Int64) -> String {
  "¥" + value.formatted(.number.grouping(.automatic))
}

extension DepreciationMethod {
  fileprivate var japaneseLabel: String {
    switch self {
    case .straightLine: "定額法"
    case .decliningBalance: "定率法"
    case .immediateExpense: "少額資産"
    case .pooledThreeYear: "一括償却（3年）"
    }
  }
}

extension AgingBucket {
  fileprivate var japaneseLabel: String {
    switch self {
    case .current: "期限内"
    case .days1To30: "1〜30日"
    case .days31To60: "31〜60日"
    case .days61To90: "61〜90日"
    case .over90: "90日超"
    }
  }
}

extension TaxRate {
  fileprivate var closingJapaneseLabel: String {
    switch self {
    case .standard10: "標準税率 10%"
    case .reduced8: "軽減税率 8%"
    case .exempt: "非課税"
    case .outOfScope: "対象外"
    }
  }
}

extension InvoiceRegistrationStatus {
  fileprivate var closingJapaneseLabel: String {
    switch self {
    case .qualified: "適格請求書"
    case .exemptOrUnregistered: "免税・未登録"
    case .unknown: "未確認"
    }
  }
}
