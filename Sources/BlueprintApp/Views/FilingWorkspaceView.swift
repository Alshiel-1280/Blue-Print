import BlueprintDomain
import BlueprintETax
import BlueprintFiling
import BlueprintTax
import SwiftUI
import UniformTypeIdentifiers

private enum FilingMode: String, CaseIterable, Identifiable {
  case summary = "申告サマリー"
  case wages = "給与"
  case property = "不動産"
  case securities = "株式・配当"
  case other = "その他・控除"
  case eTax = "青色申告・e-Tax"

  var id: String { rawValue }
}

private enum FilingEntryKind: String, Identifiable {
  case wage
  case property
  case rent
  case securities
  case loss
  case otherIncome
  case deduction
  case unsupported

  var id: String { rawValue }
}

struct FilingWorkspaceView: View {
  @ObservedObject var model: AppModel
  @State private var mode: FilingMode = .summary
  @State private var entryKind: FilingEntryKind?
  @State private var exportDocument: FilingXTXDocument?
  @State private var pendingExport: ETaxGeneratedPackage?
  @State private var exportFileName = "blue-print.xtx"
  @State private var isExporting = false
  @State private var isImportingReceipt = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      switch mode {
      case .summary: summaryWorkspace
      case .wages: wageWorkspace
      case .property: propertyWorkspace
      case .securities: securitiesWorkspace
      case .other: otherWorkspace
      case .eTax: eTaxWorkspace
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(item: $entryKind) { kind in
      FilingEntrySheet(model: model, kind: kind) { entryKind = nil }
    }
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: UTType(filenameExtension: "xtx") ?? .xml,
      defaultFilename: exportFileName
    ) { result in
      switch result {
      case .success:
        if let pendingExport { model.recordETaxExport(pendingExport) }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
      exportDocument = nil
      pendingExport = nil
    }
    .fileImporter(
      isPresented: $isImportingReceipt,
      allowedContentTypes: [.pdf, .png, .jpeg, .heic],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        model.attachETaxReceipt(from: url)
      } else if case .failure(let error) = result {
        model.errorMessage = error.localizedDescription
      }
    }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("申告ワークスペース")
          .font(.system(size: 28, weight: .semibold))
        Text("事業帳簿を変更せず、申告年度の所得・源泉税・控除資料を集約します。")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("表示", selection: $mode) {
        ForEach(FilingMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .frame(width: 650)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var summaryWorkspace: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 16) {
          summaryCard("事業所得", model.filingSummary?.businessIncome.income.yen ?? 0, .indigo)
          summaryCard("源泉税", model.filingSummary?.withholdingTax.yen ?? 0, .orange)
          summaryCard("控除資料", model.filingSummary?.deductions.yen ?? 0, .green)
          VStack(alignment: .leading, spacing: 5) {
            Text("要確認").font(.caption).foregroundStyle(.secondary)
            Text("\(model.filingSummary?.attentionCount ?? 0) 件")
              .font(.title2.weight(.semibold).monospacedDigit())
              .foregroundStyle((model.filingSummary?.attentionCount ?? 0) > 0 ? .orange : .green)
            Text("申告前チェック").font(.caption2).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 12) {
            Label("事業所得（読取専用）", systemImage: "lock.fill")
              .font(.headline)
            filingAmount("収入", model.annualProfitAndLoss?.totalRevenue.yen ?? 0)
            filingAmount("必要経費", model.annualProfitAndLoss?.totalExpenses.yen ?? 0)
            filingAmount("所得", model.annualProfitAndLoss?.profit.yen ?? 0, emphasized: true)
            Text("決算・レポートから自動連携。ここでは編集できません。")
              .font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          VStack(alignment: .leading, spacing: 12) {
            Text("所得別集約").font(.headline)
            filingAmount("給与収入", model.filingSummary?.wageRevenue.yen ?? 0)
            filingAmount("不動産所得", model.filingSummary?.propertyIncome.yen ?? 0)
            filingAmount("株式・配当", model.filingSummary?.securitiesIncome.yen ?? 0)
            filingAmount("その他所得", model.filingSummary?.otherIncome.yen ?? 0)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        Divider()
        HStack {
          Text("申告前チェック").font(.headline)
          Spacer()
          Text("資料添付 \(model.filingWorkspace?.attachments.count ?? 0)件")
            .font(.caption).foregroundStyle(.secondary)
        }
        if reviewRows.isEmpty {
          Label("確認が必要な項目はありません", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          ForEach(reviewRows) { row in
            HStack(spacing: 12) {
              Image(systemName: row.icon).foregroundStyle(row.tint)
              VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline.weight(.semibold))
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(row.state).font(.caption.weight(.semibold)).foregroundStyle(row.tint)
            }
            .padding(.vertical, 5)
            Divider()
          }
        }
      }
      .padding(24)
    }
  }

  private var wageWorkspace: some View {
    VStack(spacing: 0) {
      workspaceToolbar(
        title: "源泉徴収票",
        detail: "複数の支払者を年度単位で集計し、原本証憑と入力値を関連付けます。",
        primaryTitle: "源泉徴収票を追加",
        action: { entryKind = .wage }
      )
      Table(model.wageStatements) {
        TableColumn("支払者") { Text($0.payerName) }.width(min: 180)
        TableColumn("支払金額") { Text(yenFiling($0.paymentAmount.yen)).monospacedDigit() }
        TableColumn("源泉税") { Text(yenFiling($0.withholdingTax.yen)).monospacedDigit() }
        TableColumn("社会保険料") { Text(yenFiling($0.socialInsurance.yen)).monospacedDigit() }
        TableColumn("原本") { Text($0.evidenceDocumentID == nil ? "未添付" : "添付済み") }
        TableColumn("状態") { Text($0.reviewState.japaneseLabel) }
      }
      .overlay { if model.wageStatements.isEmpty { empty("源泉徴収票はありません", "doc.text") } }
    }
  }

  private var propertyWorkspace: some View {
    VStack(spacing: 0) {
      workspaceToolbar(
        title: "不動産所得",
        detail: "事業帳簿と分離した不動産帳簿です。共通経費と物件別経費を区別します。",
        primaryTitle: "物件を追加",
        action: { entryKind = .property },
        secondaryTitle: "収支を追加",
        secondaryAction: { entryKind = .rent }
      )
      HStack(spacing: 24) {
        summaryCard("家賃収入", model.propertyIncomeReport.revenue.yen, .indigo)
        summaryCard("必要経費", model.propertyIncomeReport.expenses.yen, .orange)
        summaryCard("減価償却", model.propertyIncomeReport.depreciation.yen, .secondary)
        summaryCard("不動産所得", model.propertyIncomeReport.income.yen, .green)
      }
      .padding(.horizontal, 20).padding(.bottom, 16)
      HSplitView {
        Table(model.filingProperties) {
          TableColumn("物件") { Text($0.name) }
          TableColumn("入居者") { Text($0.tenantName) }
          TableColumn("住所") { Text($0.address) }
        }
        .frame(minWidth: 430)
        Table(model.rentalLedgerEntries) {
          TableColumn("日付") { Text($0.transactionDate.formatted(date: .numeric, time: .omitted)) }
          TableColumn("内容") { Text($0.description) }
          TableColumn("区分") { Text($0.kind.japaneseLabel) }
          TableColumn("金額") { Text(yenFiling($0.amount.yen)).monospacedDigit() }
          TableColumn("配賦") { Text($0.isCommonExpense ? "共通" : "物件別") }
        }
        .frame(minWidth: 620)
      }
    }
  }

  private var securitiesWorkspace: some View {
    VStack(spacing: 0) {
      workspaceToolbar(
        title: "株式・配当",
        detail: "証券会社・特定口座ごとの年間報告と損失繰越を管理します。申告方法は要判断として残します。",
        primaryTitle: "年間報告を追加",
        action: { entryKind = .securities },
        secondaryTitle: "損失繰越を追加",
        secondaryAction: { entryKind = .loss }
      )
      Table(model.securitiesReports) {
        TableColumn("証券会社") { Text($0.brokerName) }.width(min: 150)
        TableColumn("口座") { Text($0.accountName) }
        TableColumn("源泉") { Text($0.withholdingKind.japaneseLabel) }
        TableColumn("譲渡対価") { Text(yenFiling($0.proceeds.yen)).monospacedDigit() }
        TableColumn("取得費") { Text(yenFiling($0.acquisitionCost.yen)).monospacedDigit() }
        TableColumn("損益") { Text(yenFiling($0.capitalGainOrLoss.yen)).monospacedDigit() }
        TableColumn("配当") { Text(yenFiling($0.dividendAmount.yen)).monospacedDigit() }
        TableColumn("状態") { Text($0.reviewState.japaneseLabel) }
      }
      .frame(minHeight: 250)
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("上場株式等の損失繰越").font(.headline)
        ForEach(model.stockLossCarryforwards) { row in
          HStack {
            Text("\(row.sourceYear)年発生")
            Spacer()
            filingAmountInline("前年以前", row.broughtForward.yen)
            filingAmountInline("当年損失", row.currentYearLoss.yen)
            filingAmountInline("当年利用", row.utilized.yen)
            filingAmountInline("翌年繰越", row.carriedForward.yen)
          }
          Divider()
        }
        if model.stockLossCarryforwards.isEmpty {
          Text("登録された損失繰越はありません。").foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
  }

  private var eTaxWorkspace: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            Text("対象年度").font(.caption).foregroundStyle(.secondary)
            Text(model.fiscalYear.map { "\($0.calendarYear)年分" } ?? "未設定")
              .font(.title2.weight(.semibold))
            Text(model.currentFormRuleSet?.procedureID ?? "年度ルール未対応")
              .font(.caption2).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 5) {
            Text("青色申告特別控除").font(.caption).foregroundStyle(.secondary)
            Text(yenFiling(model.blueReturnDeductionAssessment?.candidateAmount.yen ?? 0))
              .font(.title2.weight(.semibold).monospacedDigit())
            Text(
              model.blueReturnDeductionAssessment?.isEligible == true
                ? "適用候補" : "不足要件あり"
            )
            .font(.caption2).foregroundStyle(
              model.blueReturnDeductionAssessment?.isEligible == true ? .green : .orange)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 5) {
            Text("出力前検証").font(.caption).foregroundStyle(.secondary)
            let errors = model.eTaxValidationIssues.filter { $0.severity == .error }.count
            Text(errors == 0 ? "準備完了" : "\(errors)件のエラー")
              .font(.title2.weight(.semibold))
              .foregroundStyle(errors == 0 ? .green : .red)
            Text("必須・型・桁・帳票整合").font(.caption2).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 5) {
            Text("最終出力").font(.caption).foregroundStyle(.secondary)
            Text(
              model.eTaxExports.first?.exportedAt.formatted(date: .numeric, time: .shortened)
                ?? "未出力"
            )
            .font(.title3.weight(.semibold))
            Text(model.eTaxNeedsRegeneration ? "帳簿変更あり・再出力が必要" : "最新の帳簿と一致")
              .font(.caption2)
              .foregroundStyle(model.eTaxNeedsRegeneration ? .orange : .secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()

        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 12) {
            Label("青色申告決算書 確認表示", systemImage: "doc.text.magnifyingglass")
              .font(.headline)
            if let package = model.blueReturnPackage {
              filingAmount("事業収入", package.business.totalRevenue.yen)
              filingAmount("必要経費", package.business.totalExpenses.yen)
              filingAmount("事業所得", package.business.incomeBeforeDeduction.yen, emphasized: true)
              filingAmount("資産合計", package.business.totalAssets.yen)
              filingAmount("負債・資本合計", package.business.totalLiabilitiesAndEquity.yen)
              Divider()
              filingAmount("不動産収入", package.property.revenue.yen)
              filingAmount("不動産所得", package.property.incomeBeforeDeduction.yen, emphasized: true)
            } else {
              Text("決算結果を生成すると帳票を確認できます。")
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)

          VStack(alignment: .leading, spacing: 12) {
            Label("年度ルール", systemImage: "calendar.badge.checkmark")
              .font(.headline)
            if let rules = model.currentFormRuleSet {
              HStack {
                Text("手続")
                Spacer()
                Text("\(rules.procedureID) v\(rules.procedureVersion)")
              }
              ForEach(rules.forms) { form in
                HStack {
                  Text(form.name).lineLimit(1)
                  Spacer()
                  Text("\(form.id) v\(form.version)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
              }
              Text("根拠確認日とURLはバージョン情報へ保存されています。")
                .font(.caption).foregroundStyle(.secondary)
            } else {
              Text("この年度のルールは未対応です。")
                .foregroundStyle(.orange)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
          Text("出力前チェック").font(.headline)
          if model.eTaxValidationIssues.isEmpty {
            Label("必須項目・型・桁数・帳票間整合を確認しました", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            ForEach(model.eTaxValidationIssues) { issue in
              HStack(alignment: .top, spacing: 10) {
                Image(
                  systemName: issue.severity == .error
                    ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(issue.severity == .error ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                  Text(issue.message)
                  if let tag = issue.fieldTag {
                    Text(tag).font(.caption.monospaced()).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }

        if let checklist = model.eTaxReturnData?.checklist {
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Text("出力内容とe-Tax追加入力").font(.headline)
            ForEach(checklist) { item in
              HStack(alignment: .top, spacing: 10) {
                Image(
                  systemName: item.state == .included
                    ? "checkmark.circle.fill" : "arrow.right.circle.fill"
                )
                .foregroundStyle(item.state == .included ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).font(.subheadline.weight(.semibold))
                  Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        Divider()

        HStack(spacing: 12) {
          Button(".xtxを書き出す", systemImage: "square.and.arrow.up") {
            guard let package = model.generateETaxPackage() else { return }
            pendingExport = package
            exportDocument = FilingXTXDocument(data: package.data)
            exportFileName = package.fileName
            isExporting = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.eTaxValidationIssues.contains { $0.severity == .error })
          Button("受付通知・申告控えを添付", systemImage: "paperclip") {
            isImportingReceipt = true
          }
          .buttonStyle(.bordered)
          Spacer()
          Text("署名・送信はe-Tax WEB版で行います")
            .font(.caption).foregroundStyle(.secondary)
        }

        if !model.eTaxExports.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("出力履歴").font(.headline)
            ForEach(model.eTaxExports) { record in
              HStack {
                Text(record.exportedAt.formatted(date: .numeric, time: .shortened))
                Text(record.fileName)
                Spacer()
                Text(String(record.fileHash.prefix(12)))
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              .padding(.vertical, 3)
            }
          }
        }
      }
      .padding(24)
    }
  }

  private var otherWorkspace: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("その他所得・控除").font(.title2.weight(.semibold))
          Spacer()
          Button("その他所得", systemImage: "plus") { entryKind = .otherIncome }
          Button("控除資料", systemImage: "plus") { entryKind = .deduction }
          Button("e-Tax追加入力", systemImage: "exclamationmark.triangle") {
            entryKind = .unsupported
          }
        }
        Text("雑所得、公的年金、一時・退職所得と、医療費・保険料・寄附等を申告年度へ集約します。")
          .foregroundStyle(.secondary)
        Divider()
        Text("その他所得").font(.headline)
        ForEach(model.otherIncomeEntries) { row in
          filingRow(
            title: row.title,
            subtitle: row.kind.japaneseLabel,
            amount: row.income.yen,
            state: row.reviewState.japaneseLabel)
        }
        Divider()
        Text("所得控除資料").font(.headline)
        ForEach(model.filingDeductions) { row in
          filingRow(
            title: row.title,
            subtitle: row.kind.japaneseLabel,
            amount: row.amount.yen,
            state: row.reviewState.japaneseLabel)
        }
        Divider()
        Text("e-Tax WEB版で追加入力").font(.headline)
        ForEach(model.unsupportedFilingCases) { row in
          HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
              Text(row.title).font(.subheadline.weight(.semibold))
              Text(row.guidance).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.state.japaneseLabel).font(.caption).foregroundStyle(.orange)
          }
          Divider()
        }
      }
      .padding(24)
    }
  }

  private var reviewRows: [FilingReviewRow] {
    let workspace = (model.filingWorkspace?.unresolvedItems ?? []).map {
      FilingReviewRow(
        id: $0.id, title: $0.title, detail: $0.detail, state: $0.state.japaneseLabel,
        icon: "questionmark.circle", tint: .orange)
    }
    let wages = model.wageStatements.filter { $0.reviewState != .confirmed }.map {
      FilingReviewRow(
        id: $0.id, title: $0.payerName, detail: "源泉徴収票の原本または入力値を確認",
        state: $0.reviewState.japaneseLabel, icon: "doc.text", tint: .blue)
    }
    let securities = model.securitiesReports.filter { $0.reviewState != .confirmed }.map {
      FilingReviewRow(
        id: $0.id, title: $0.brokerName, detail: "配当・譲渡所得の申告方法を確認",
        state: $0.reviewState.japaneseLabel, icon: "chart.line.uptrend.xyaxis", tint: .orange)
    }
    let otherIncome = model.otherIncomeEntries.filter { $0.reviewState != .confirmed }.map {
      FilingReviewRow(
        id: $0.id, title: $0.title, detail: "その他所得の区分・収入・経費を確認",
        state: $0.reviewState.japaneseLabel, icon: "tray.full", tint: .blue)
    }
    let deductions = model.filingDeductions.filter { $0.reviewState != .confirmed }.map {
      FilingReviewRow(
        id: $0.id, title: $0.title, detail: "控除証明書と集計額を確認",
        state: $0.reviewState.japaneseLabel, icon: "checkmark.seal", tint: .blue)
    }
    let unsupported = model.unsupportedFilingCases.filter { $0.state != .confirmed }.map {
      FilingReviewRow(
        id: $0.id, title: $0.title, detail: $0.guidance, state: $0.state.japaneseLabel,
        icon: "exclamationmark.triangle", tint: .orange)
    }
    return workspace + wages + securities + otherIncome + deductions + unsupported
  }

  private func workspaceToolbar(
    title: String,
    detail: String,
    primaryTitle: String,
    action: @escaping () -> Void,
    secondaryTitle: String? = nil,
    secondaryAction: (() -> Void)? = nil
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let secondaryTitle, let secondaryAction {
        Button(secondaryTitle, action: secondaryAction)
      }
      Button(primaryTitle, systemImage: "plus", action: action)
        .buttonStyle(.borderedProminent)
    }
    .padding(20)
  }

  private func summaryCard(_ title: String, _ value: Int64, _ tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(yenFiling(value)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
      Text("\(model.fiscalYear?.calendarYear ?? 0)年度").font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func filingAmount(_ title: String, _ value: Int64, emphasized: Bool = false) -> some View
  {
    HStack {
      Text(title)
      Spacer()
      Text(yenFiling(value))
        .font(emphasized ? .headline : .body)
        .monospacedDigit()
    }
  }

  private func filingAmountInline(_ title: String, _ value: Int64) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(yenFiling(value)).monospacedDigit()
    }
    .frame(width: 115, alignment: .trailing)
  }

  private func filingRow(title: String, subtitle: String, amount: Int64, state: String) -> some View
  {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(state).font(.caption).foregroundStyle(.orange)
      Text(yenFiling(amount)).monospacedDigit().frame(width: 130, alignment: .trailing)
    }
    .padding(.vertical, 4)
  }

  private func empty(_ title: String, _ icon: String) -> some View {
    ContentUnavailableView(title, systemImage: icon, description: Text("右上の追加ボタンから登録できます。"))
  }
}

private struct FilingReviewRow: Identifiable {
  let id: EntityID
  let title: String
  let detail: String
  let state: String
  let icon: String
  let tint: Color
}

private struct FilingEntrySheet: View {
  @ObservedObject var model: AppModel
  let kind: FilingEntryKind
  let dismiss: () -> Void
  @State private var title = ""
  @State private var detail = ""
  @State private var amount = 0
  @State private var secondaryAmount = 0
  @State private var thirdAmount = 0
  @State private var fourthAmount = 0
  @State private var fifthAmount = 0
  @State private var sixthAmount = 0
  @State private var date = Date()
  @State private var sourceYear = 2025
  @State private var propertyID: EntityID?
  @State private var evidenceID: EntityID?
  @State private var rentalKind: RentalLedgerEntryKind = .rentRevenue
  @State private var withholdingKind: SecuritiesWithholdingKind = .withholding
  @State private var otherIncomeKind: OtherIncomeKind = .miscellaneous
  @State private var deductionKind: DeductionKind = .medical

  var body: some View {
    Form {
      Text(sheetTitle).font(.title2.weight(.semibold))
      fields
      HStack {
        Spacer()
        Button("キャンセル", action: dismiss)
        Button("保存", action: save)
          .buttonStyle(.borderedProminent)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear { seedDefaults() }
  }

  @ViewBuilder private var fields: some View {
    switch kind {
    case .wage:
      TextField("支払者", text: $title)
      money("支払金額", $amount)
      money("源泉徴収税額", $secondaryAmount)
      money("社会保険料等", $thirdAmount)
      evidencePicker
    case .property:
      TextField("物件名", text: $title)
      TextField("住所", text: $detail)
      TextField("入居者名", text: $tenantName)
    case .rent:
      Picker("物件・配賦", selection: $propertyID) {
        Text("共通経費").tag(EntityID?.none)
        ForEach(model.filingProperties) { Text($0.name).tag(EntityID?.some($0.id)) }
      }
      Picker("区分", selection: $rentalKind) {
        ForEach(RentalLedgerEntryKind.allCases, id: \.self) {
          Text($0.japaneseLabel).tag($0)
        }
      }
      DatePicker("日付", selection: $date, displayedComponents: .date)
      TextField("内容", text: $title)
      money("金額", $amount)
      evidencePicker
    case .securities:
      TextField("証券会社", text: $title)
      TextField("口座名", text: $detail)
      Picker("源泉区分", selection: $withholdingKind) {
        ForEach(SecuritiesWithholdingKind.allCases, id: \.self) {
          Text($0.japaneseLabel).tag($0)
        }
      }
      money("譲渡対価", $amount)
      money("取得費", $secondaryAmount)
      money("所得税", $thirdAmount)
      money("住民税", $fourthAmount)
      money("配当額", $fifthAmount)
      money("配当源泉税", $sixthAmount)
      evidencePicker
    case .loss:
      TextField("管理名", text: $title)
      Stepper("発生年 \(sourceYear)年", value: $sourceYear, in: 2000...2100)
      money("前年以前繰越", $amount)
      money("当年損失", $secondaryAmount)
      money("当年利用", $thirdAmount)
    case .otherIncome:
      TextField("所得・資料名", text: $title)
      Picker("所得区分", selection: $otherIncomeKind) {
        ForEach(OtherIncomeKind.allCases, id: \.self) { Text($0.japaneseLabel).tag($0) }
      }
      money("収入", $amount)
      money("必要経費", $secondaryAmount)
      money("源泉税", $thirdAmount)
      evidencePicker
    case .deduction:
      TextField("資料名", text: $title)
      Picker("控除区分", selection: $deductionKind) {
        ForEach(DeductionKind.allCases, id: \.self) { Text($0.japaneseLabel).tag($0) }
      }
      money("金額", $amount)
      evidencePicker
    case .unsupported:
      TextField("未対応ケース", text: $title)
      TextField("e-Taxでの対応方法", text: $detail, axis: .vertical)
        .lineLimit(3...6)
    }
  }

  @State private var tenantName = ""

  private var evidencePicker: some View {
    Picker("原本証憑", selection: $evidenceID) {
      Text("未添付").tag(EntityID?.none)
      ForEach(model.evidenceDocuments) {
        Text($0.originalFilename).tag(EntityID?.some($0.id))
      }
    }
  }

  private func money(_ label: String, _ value: Binding<Int>) -> some View {
    TextField(label, value: value, format: .number)
  }

  private var sheetTitle: String {
    switch kind {
    case .wage: "源泉徴収票を追加"
    case .property: "物件を追加"
    case .rent: "不動産収支を追加"
    case .securities: "特定口座年間報告を追加"
    case .loss: "株式損失繰越を追加"
    case .otherIncome: "その他所得を追加"
    case .deduction: "控除資料を追加"
    case .unsupported: "e-Tax追加入力を記録"
    }
  }

  private func seedDefaults() {
    if kind == .loss {
      title = "上場株式等の譲渡損失"
      sourceYear = (model.fiscalYear?.calendarYear ?? 2026) - 1
    } else if kind == .unsupported {
      detail = "この項目はBlue-Printで自動生成せず、e-Tax WEB版で追加入力してください。"
    }
  }

  private func save() {
    switch kind {
    case .wage:
      model.saveWageStatement(
        payerName: title,
        paymentAmount: Int64(amount),
        withholdingTax: Int64(secondaryAmount),
        socialInsurance: Int64(thirdAmount),
        evidenceDocumentID: evidenceID)
    case .property:
      model.saveFilingProperty(name: title, address: detail, tenantName: tenantName)
    case .rent:
      model.saveRentalEntry(
        propertyID: propertyID, transactionDate: date, kind: rentalKind, description: title,
        amount: Int64(amount), evidenceDocumentID: evidenceID)
    case .securities:
      model.saveSecuritiesReport(
        brokerName: title, accountName: detail, withholdingKind: withholdingKind,
        proceeds: Int64(amount), acquisitionCost: Int64(secondaryAmount),
        nationalTax: Int64(thirdAmount), localTax: Int64(fourthAmount),
        dividend: Int64(fifthAmount), dividendTax: Int64(sixthAmount),
        evidenceDocumentID: evidenceID)
    case .loss:
      model.saveStockLossCarryforward(
        sourceYear: sourceYear, broughtForward: Int64(amount),
        currentLoss: Int64(secondaryAmount), utilized: Int64(thirdAmount))
    case .otherIncome:
      model.saveOtherIncome(
        kind: otherIncomeKind, title: title, revenue: Int64(amount),
        expenses: Int64(secondaryAmount), withholdingTax: Int64(thirdAmount),
        evidenceDocumentID: evidenceID)
    case .deduction:
      model.saveFilingDeduction(
        kind: deductionKind, title: title, amount: Int64(amount), evidenceDocumentID: evidenceID)
    case .unsupported:
      model.saveUnsupportedFilingCase(title: title, guidance: detail)
    }
    dismiss()
  }
}

private func yenFiling(_ value: Int64) -> String {
  "¥" + value.formatted(.number.grouping(.automatic))
}

private struct FilingXTXDocument: FileDocument {
  static var readableContentTypes: [UTType] { [UTType(filenameExtension: "xtx") ?? .xml] }
  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension FilingReviewState {
  fileprivate var japaneseLabel: String {
    switch self {
    case .unconfirmed: "未確認"
    case .needsDecision: "要判断"
    case .additionalETaxInput: "e-Tax追加入力"
    case .confirmed: "確認済み"
    }
  }
}

extension RentalLedgerEntryKind {
  fileprivate var japaneseLabel: String {
    switch self {
    case .rentRevenue: "家賃収入"
    case .expense: "必要経費"
    case .depreciation: "減価償却"
    }
  }
}

extension SecuritiesWithholdingKind {
  fileprivate var japaneseLabel: String {
    switch self {
    case .withholding: "源泉あり"
    case .noWithholding: "源泉なし"
    }
  }
}

extension OtherIncomeKind {
  fileprivate var japaneseLabel: String {
    switch self {
    case .miscellaneous: "雑所得"
    case .publicPension: "公的年金"
    case .temporary: "一時所得"
    case .retirement: "退職所得"
    }
  }
}

extension DeductionKind {
  fileprivate var japaneseLabel: String {
    switch self {
    case .medical: "医療費控除"
    case .socialInsurance: "社会保険料控除"
    case .lifeInsurance: "生命保険料控除"
    case .earthquakeInsurance: "地震保険料控除"
    case .donation: "寄附金控除"
    case .dependent: "扶養控除"
    case .other: "その他控除"
    }
  }
}
