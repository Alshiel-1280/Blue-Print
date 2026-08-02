import BlueprintDomain
import BlueprintImports
import BlueprintTax
import BlueprintTransfer
import SwiftUI
import UniformTypeIdentifiers

struct V2RootView: View {
  @ObservedObject var store: V2WorkspaceStore

  var body: some View {
    NavigationSplitView {
      List(V2Destination.allCases, selection: $store.selectedDestination) { destination in
        Label(destination.title, systemImage: destination.symbol)
          .tag(destination)
          .disabled(destination == .filing && !store.isFilingSupported)
          .accessibilityHint(
            destination == .filing && !store.isFilingSupported
              ? "この年度の署名済み申告ルールが未提供のため選択できません"
              : "\(destination.title)ワークスペースを開きます"
          )
      }
      .navigationTitle(store.profile?.tradeName ?? "Blue-Print")
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
          Text(store.fiscalYear.map { "\($0.calendarYear)年" } ?? "年度未設定")
            .font(.caption.bold())
          Text("v\(BlueprintVersions.app)・データ世代\(BlueprintVersions.storageGeneration)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
    } detail: {
      Group {
        switch store.selectedDestination {
        case .home: V2HomeView(store: store)
        case .daily: V2DailyView(store: store)
        case .books: V2BooksView(store: store)
        case .closing: V2ClosingView(store: store)
        case .filing: V2FilingView(store: store)
        case .utilities: V2UtilitiesView(store: store)
        }
      }
      .frame(minWidth: 760, minHeight: 600)
    }
  }
}

struct V2InitialSetupView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var ownerName = ""
  @State private var tradeName = ""
  @State private var year = 2026
  @State private var consumption: ConsumptionTaxStatus = .exempt
  @State private var invoice: InvoiceRegistrationStatus = .exemptOrUnregistered

  private var supportedYears: [Int] {
    store.supportedYears.filter {
      store.support(for: $0)?.supports(.bookkeeping) == true
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Label("Blue-Print v2", systemImage: "building.columns.fill")
        .font(.largeTitle.bold())
        .foregroundStyle(.indigo)
      Text("新しいデータ世代を作成します。v1の保存先・バックアップは読み込み、コピー、削除しません。")
        .foregroundStyle(.secondary)
        .accessibilityLabel("v2は新しい保存領域を使用し、v1データには一切変更を加えません")

      Form {
        TextField("氏名", text: $ownerName)
        TextField("屋号", text: $tradeName)
        Picker("年度", selection: $year) {
          ForEach(supportedYears, id: \.self) { Text("\($0)年").tag($0) }
        }
        Picker("消費税", selection: $consumption) {
          Text("免税").tag(ConsumptionTaxStatus.exempt)
          Text("課税").tag(ConsumptionTaxStatus.generalTaxation)
          Text("簡易課税").tag(ConsumptionTaxStatus.simplifiedTaxation)
        }
        Picker("インボイス登録", selection: $invoice) {
          Text("未登録").tag(InvoiceRegistrationStatus.exemptOrUnregistered)
          Text("登録済み").tag(InvoiceRegistrationStatus.qualified)
        }
      }
      .formStyle(.grouped)

      if store.support(for: year)?.supports(.xtx) != true {
        Label(
          "\(year)年の申告書・XTXは、国税庁の最終仕様と実読込検証が完了するまで無効です。",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("v2データを作成") {
          store.createInitialSetup(
            ownerName: ownerName,
            tradeName: tradeName,
            calendarYear: year,
            consumptionTaxStatus: consumption,
            invoiceStatus: invoice
          )
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("入力した内容で新しいv2データベースを作成します")
        .disabled(
          ownerName.trimmingCharacters(in: .whitespaces).isEmpty
            || tradeName.trimmingCharacters(in: .whitespaces).isEmpty || store.isWorking)
      }
    }
    .padding(40)
    .frame(minWidth: 620, minHeight: 560)
    .onAppear {
      if !supportedYears.contains(year), let latest = supportedYears.max() { year = latest }
    }
  }
}

private struct V2HomeView: View {
  @ObservedObject var store: V2WorkspaceStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("ホーム").font(.largeTitle.bold())
        Text("確認が必要なものと、次に行う作業をまとめています。")
          .foregroundStyle(.secondary)

        LazyVGrid(columns: [.init(.adaptive(minimum: 210))], spacing: 14) {
          V2MetricCard(
            title: "未処理ジョブ",
            value: store.jobs.filter { $0.state != .succeeded && $0.state != .cancelled }.count,
            detail: "終了後も再開可能",
            symbol: "clock.arrow.circlepath"
          )
          V2MetricCard(
            title: "仕訳",
            value: store.journalEntries.count,
            detail: store.trialBalance?.isBalanced == true ? "貸借一致" : "確認が必要",
            symbol: "book.closed"
          )
          V2MetricCard(
            title: "決算ブロッカー",
            value: store.closingBlockers.count,
            detail: store.closingBlockers.first ?? "決算へ進めます",
            symbol: "checkmark.seal"
          )
          V2MetricCard(
            title: "申告ブロッカー",
            value: store.filingBlockers.count,
            detail: store.filingBlockers.first ?? "XTX出力準備完了",
            symbol: "doc.badge.clock"
          )
        }

        GroupBox("次の一手") {
          VStack(alignment: .leading, spacing: 10) {
            if store.journalEntries.isEmpty {
              Button("最初の仕訳を入力") { store.selectedDestination = .daily }
            } else if !store.closingBlockers.isEmpty {
              Button("決算ブロッカーを確認") { store.selectedDestination = .closing }
            } else {
              Button("帳簿を確認") { store.selectedDestination = .books }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }
      }
      .padding(28)
    }
  }
}

private struct V2DailyView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var date = Date()
  @State private var description = ""
  @State private var amountText = ""
  @State private var debitID: EntityID?
  @State private var creditID: EntityID?
  @State private var taxRate: TaxRate = .standard10
  @State private var invoiceStatus: InvoiceRegistrationStatus = .unknown
  @State private var importingEvidence = false
  @State private var importingCSV = false
  @State private var csvURL: URL?
  @State private var templateName = ""
  @State private var templateDescription = ""
  @State private var templateDebitID: EntityID?
  @State private var templateCreditID: EntityID?
  @State private var recurringTemplateID: UUID?
  @State private var recurringAmount = ""
  @State private var recurringDate = Date()
  @State private var ruleName = ""
  @State private var ruleContains = ""
  @State private var counterpartyCode = ""
  @State private var counterpartyName = ""
  @State private var invoiceCounterpartyID: UUID?
  @State private var invoiceNumber = ""
  @State private var invoiceSubject = ""
  @State private var invoiceAmount = ""
  @State private var invoiceDueDate = Date().addingTimeInterval(30 * 86_400)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("日常処理").font(.largeTitle.bold())
        Text("候補の生成と確定を分け、確認なしに自動確定しません。")
          .foregroundStyle(.secondary)

        GroupBox("入出金・証憑・仕訳の照合") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Button("入出金CSVを選択") { importingCSV = true }
              Button("照合候補を再生成") { store.generateMatchCandidates() }
                .disabled(store.importCandidates.isEmpty || store.evidenceDocuments.isEmpty)
              Text("照合も仕訳も明示確認するまで確定しません")
                .foregroundStyle(.secondary)
            }
            ForEach(store.matchCandidates) { match in
              let imported = store.importCandidates.first { $0.id == match.importCandidateID }
              let evidence = store.evidenceDocuments.first { $0.id == match.evidenceID }
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(imported?.candidate.description ?? "入出金候補").font(.headline)
                  Spacer()
                  Text(
                    "\(match.confidenceBasisPoints.formatted()) / 10,000"
                  ).monospacedDigit()
                }
                Text(
                  "\(evidence?.originalFilename ?? "証憑")・\(match.explanation)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if match.journalCandidateID == nil {
                  Label(
                    "一致する仕訳ルールがないため、先にルールを作成してください",
                    systemImage: "exclamationmark.triangle"
                  )
                  .font(.caption)
                  .foregroundStyle(.orange)
                }
                HStack {
                  Button("照合を確認") { store.acceptMatch(match) }
                    .buttonStyle(.borderedProminent)
                  Button("一致しない", role: .destructive) { store.rejectMatch(match) }
                }
              }
              .padding(.vertical, 5)
              .accessibilityElement(children: .contain)
              Divider()
            }
            if store.matchCandidates.isEmpty {
              Text("確認待ちの照合候補はありません。")
                .foregroundStyle(.secondary)
            }
            if !store.importCandidates.isEmpty {
              Text(
                "入出金候補 \(store.importCandidates.count)件（未処理 \(store.importCandidates.filter { $0.state == .pending }.count)件）"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
          .padding(6)
        }

        GroupBox("仕訳候補") {
          VStack(alignment: .leading, spacing: 10) {
            if !store.journalCandidates.isEmpty {
              HStack {
                Spacer()
                Button("表示中の候補を一括確認") { store.confirmAllCandidates() }
                  .help("各候補の内容を表示した状態で、明示的に確定します")
                  .accessibilityHint("表示中の全候補を仕訳として確定します。自動実行ではありません")
              }
            }
            ForEach(store.journalCandidates) { candidate in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(candidate.description).font(.headline)
                  Spacer()
                  Text(yen(candidate.amountYen)).monospacedDigit()
                }
                Text(
                  "\(store.accountName(candidate.debitAccountID)) / \(store.accountName(candidate.creditAccountID))・\(candidate.explanation)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                  Button("内容を確認して確定") { store.confirmCandidate(candidate) }
                    .buttonStyle(.borderedProminent)
                  Button("却下", role: .destructive) { store.rejectCandidate(candidate) }
                }
              }
              .padding(.vertical, 5)
              .accessibilityElement(children: .contain)
              .accessibilityLabel(
                "\(candidate.description)、\(yen(candidate.amountYen))、\(candidate.explanation)"
              )
              Divider()
            }
            if store.journalCandidates.isEmpty {
              Text("確認待ちの候補はありません。")
                .foregroundStyle(.secondary)
            }
          }
          .padding(6)
        }

        GroupBox("仕訳を入力") {
          Form {
            DatePicker("取引日", selection: $date, displayedComponents: .date)
            TextField("摘要", text: $description)
            TextField("金額", text: $amountText)
            Picker("借方", selection: $debitID) {
              Text("選択").tag(EntityID?.none)
              ForEach(store.accounts) { Text("\($0.code) \($0.name)").tag(EntityID?.some($0.id)) }
            }
            Picker("貸方", selection: $creditID) {
              Text("選択").tag(EntityID?.none)
              ForEach(store.accounts) { Text("\($0.code) \($0.name)").tag(EntityID?.some($0.id)) }
            }
            Picker("税率", selection: $taxRate) {
              ForEach(TaxRate.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            Picker("登録区分", selection: $invoiceStatus) {
              ForEach(InvoiceRegistrationStatus.allCases, id: \.self) {
                Text($0.v2LocalizedName).tag($0)
              }
            }
            HStack {
              Spacer()
              Button("確認して確定") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(debitID == nil || creditID == nil || Int64(amountText) == nil)
                .accessibilityHint("入力内容を貸借一致の仕訳として確定します")
            }
          }
          .formStyle(.grouped)
        }

        GroupBox("永続ジョブ") {
          VStack(alignment: .leading, spacing: 8) {
            Text("証憑取込とバックアップは、進捗・再開地点・失敗理由を保存します。")
              .foregroundStyle(.secondary)
            ForEach(store.jobs.suffix(5).reversed()) { job in
              HStack {
                Text(job.kind.v2LocalizedName)
                ProgressView(value: Double(job.progressBasisPoints), total: 10_000)
                  .frame(width: 120)
                Text(job.state.v2LocalizedName)
                if let reason = job.failureReason {
                  Text(reason).font(.caption).foregroundStyle(.orange)
                }
              }
              .accessibilityElement(children: .combine)
            }
            if store.jobs.isEmpty {
              Text("実行履歴はありません。").foregroundStyle(.secondary)
            }
          }
          .padding(6)
        }

        GroupBox("テンプレート・定期仕訳") {
          VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("テンプレートを作成") {
              Form {
                TextField("名前", text: $templateName)
                TextField("摘要", text: $templateDescription)
                Picker("借方", selection: $templateDebitID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(store.accounts) { Text($0.name).tag(EntityID?.some($0.id)) }
                }
                Picker("貸方", selection: $templateCreditID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(store.accounts) { Text($0.name).tag(EntityID?.some($0.id)) }
                }
                Button("テンプレートを保存") {
                  guard let debit = templateDebitID, let credit = templateCreditID else { return }
                  store.saveJournalTemplate(
                    name: templateName,
                    description: templateDescription,
                    debitAccountID: debit,
                    creditAccountID: credit,
                    taxRate: taxRate
                  )
                  templateName = ""
                  templateDescription = ""
                }
                .disabled(
                  templateName.trimmingCharacters(in: .whitespaces).isEmpty
                    || templateDescription.trimmingCharacters(in: .whitespaces).isEmpty
                    || templateDebitID == nil || templateCreditID == nil
                )
              }
              .formStyle(.grouped)
            }
            DisclosureGroup("毎月の候補を作成") {
              Form {
                Picker("テンプレート", selection: $recurringTemplateID) {
                  Text("選択").tag(UUID?.none)
                  ForEach(store.journalTemplates) {
                    Text($0.name).tag(UUID?.some($0.id))
                  }
                }
                TextField("金額", text: $recurringAmount)
                DatePicker("次回日", selection: $recurringDate, displayedComponents: .date)
                Button("定期仕訳を保存") {
                  guard let templateID = recurringTemplateID,
                    let amount = Int64(recurringAmount)
                  else { return }
                  store.saveRecurringJournal(
                    templateID: templateID,
                    amountYen: amount,
                    nextRunAt: recurringDate
                  )
                  recurringAmount = ""
                }
                .disabled(recurringTemplateID == nil || Int64(recurringAmount) == nil)
              }
              .formStyle(.grouped)
            }
            DisclosureGroup("仕訳ルールを作成") {
              Form {
                TextField("ルール名", text: $ruleName)
                TextField("摘要に含む文字", text: $ruleContains)
                Picker("借方", selection: $templateDebitID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(store.accounts) { Text($0.name).tag(EntityID?.some($0.id)) }
                }
                Picker("貸方", selection: $templateCreditID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(store.accounts) { Text($0.name).tag(EntityID?.some($0.id)) }
                }
                Button("仕訳ルールを保存") {
                  guard let debit = templateDebitID, let credit = templateCreditID else { return }
                  store.saveJournalRule(
                    name: ruleName,
                    contains: ruleContains,
                    debitAccountID: debit,
                    creditAccountID: credit,
                    taxRate: taxRate
                  )
                  ruleName = ""
                  ruleContains = ""
                }
                .disabled(
                  ruleName.trimmingCharacters(in: .whitespaces).isEmpty
                    || ruleContains.trimmingCharacters(in: .whitespaces).isEmpty
                    || templateDebitID == nil || templateCreditID == nil
                )
              }
              .formStyle(.grouped)
            }
            HStack {
              Text(
                "テンプレート \(store.journalTemplates.count)件・定期仕訳 \(store.recurringJournals.count)件・ルール \(store.journalRules.count)件"
              )
              .foregroundStyle(.secondary)
              Spacer()
              Button("期限到来分の候補を生成") { store.generateRecurringCandidates() }
            }
          }
          .padding(6)
        }

        GroupBox("証憑・OCR候補") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Button("証憑を取り込む") { importingEvidence = true }
                .accessibilityHint("PDFまたは画像を選択し、原本を保持したままOCR候補を作成します")
              Text("原本は変更せず、候補だけを生成します。")
                .foregroundStyle(.secondary)
            }
            ForEach(store.evidenceDocuments) { document in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Label(document.originalFilename, systemImage: "doc.viewfinder")
                  Spacer()
                  Text(document.state.localizedName).font(.caption)
                }
                .accessibilityElement(children: .combine)
                let candidates = store.ocrCandidatesByEvidence[document.id] ?? []
                if candidates.isEmpty {
                  Text("OCR候補なし").font(.caption).foregroundStyle(.secondary)
                } else {
                  Text(
                    candidates.map { "\($0.field.localizedName): \($0.effectiveValue)" }
                      .joined(separator: "・")
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                }
              }
              .padding(.vertical, 4)
              Divider()
            }
            if store.evidenceDocuments.isEmpty {
              ContentUnavailableView(
                "証憑はありません",
                systemImage: "doc",
                description: Text("PDFまたは画像を選択して取り込みます。")
              )
              .frame(height: 150)
            }
          }
          .padding(6)
        }

        GroupBox("取引先・請求") {
          VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("取引先を追加") {
              Form {
                TextField("コード", text: $counterpartyCode)
                TextField("名称", text: $counterpartyName)
                Button("取引先を保存") {
                  store.saveCounterparty(code: counterpartyCode, displayName: counterpartyName)
                  counterpartyCode = ""
                  counterpartyName = ""
                }
                .disabled(
                  counterpartyCode.trimmingCharacters(in: .whitespaces).isEmpty
                    || counterpartyName.trimmingCharacters(in: .whitespaces).isEmpty
                )
              }
              .formStyle(.grouped)
            }
            DisclosureGroup("請求書ドラフトを作成") {
              Form {
                Picker("取引先", selection: $invoiceCounterpartyID) {
                  Text("選択").tag(UUID?.none)
                  ForEach(store.counterparties) {
                    Text($0.displayName).tag(UUID?.some($0.id))
                  }
                }
                TextField("請求番号", text: $invoiceNumber)
                TextField("件名", text: $invoiceSubject)
                TextField("税抜金額", text: $invoiceAmount)
                DatePicker("支払期限", selection: $invoiceDueDate, displayedComponents: .date)
                Button("ドラフトを保存") {
                  guard let counterpartyID = invoiceCounterpartyID,
                    let amount = Int64(invoiceAmount)
                  else { return }
                  store.createInvoice(
                    counterpartyID: counterpartyID,
                    number: invoiceNumber,
                    subject: invoiceSubject,
                    amountYen: amount,
                    dueDate: invoiceDueDate
                  )
                  invoiceNumber = ""
                  invoiceSubject = ""
                  invoiceAmount = ""
                }
                .disabled(
                  invoiceCounterpartyID == nil
                    || invoiceNumber.trimmingCharacters(in: .whitespaces).isEmpty
                    || invoiceSubject.trimmingCharacters(in: .whitespaces).isEmpty
                    || Int64(invoiceAmount) == nil
                )
              }
              .formStyle(.grouped)
            }
            ForEach(store.invoices) { invoice in
              HStack {
                VStack(alignment: .leading) {
                  Text("\(invoice.number) \(invoice.subject)").font(.headline)
                  Text(
                    "\(invoice.status.v2LocalizedName)・残高 \(yen((try? invoice.outstandingAmount().yen) ?? 0))"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
                Spacer()
                Text(yen((try? invoice.total().yen) ?? 0)).monospacedDigit()
                if invoice.status == .draft {
                  Button("発行して仕訳") { store.issueInvoice(invoice) }
                    .disabled(store.isWorking)
                    .accessibilityHint("請求書PDFを保存し、売掛金と売上高の仕訳を確定します")
                } else if invoice.status == .issued || invoice.status == .partiallyPaid
                  || invoice.status == .overdue
                {
                  Button("全額入金") { store.settleInvoiceInFull(invoice) }
                    .disabled(store.isWorking)
                    .accessibilityHint("未入金残高を普通預金への入金として消し込みます")
                }
              }
              Divider()
            }
          }
          .padding(6)
        }
      }
      .padding(28)
    }
    .fileImporter(
      isPresented: $importingEvidence,
      allowedContentTypes: [.pdf, .image],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        for url in urls { store.importEvidence(from: url, origin: .electronicTransaction) }
      case .failure(let error):
        store.errorMessage = error.localizedDescription
      }
    }
    .fileImporter(
      isPresented: $importingCSV,
      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        csvURL = urls.first
      case .failure(let error):
        store.errorMessage = error.localizedDescription
      }
    }
    .sheet(
      isPresented: Binding(
        get: { csvURL != nil },
        set: { if !$0 { csvURL = nil } }
      )
    ) {
      if let csvURL {
        V2CSVImportSheet(store: store, sourceURL: csvURL) {
          self.csvURL = nil
        }
      }
    }
    .onAppear {
      debitID = debitID ?? store.accounts.first(where: { $0.category == .expense })?.id
      creditID = creditID ?? store.accounts.first(where: { $0.code == "1000" })?.id
      templateDebitID = templateDebitID ?? debitID
      templateCreditID = templateCreditID ?? creditID
      if let year = store.fiscalYear?.calendarYear {
        let componentYear = Calendar.current.component(.year, from: date)
        if componentYear != year {
          date = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
        }
      }
    }
  }

  private func submit() {
    guard let debitID, let creditID, let amount = Int64(amountText) else { return }
    store.postJournal(
      date: date,
      description: description,
      debitAccountID: debitID,
      creditAccountID: creditID,
      amountYen: amount,
      taxRate: taxRate,
      invoiceStatus: invoiceStatus
    )
    description = ""
    amountText = ""
  }
}

private struct V2CSVImportSheet: View {
  @ObservedObject var store: V2WorkspaceStore
  let sourceURL: URL
  let dismiss: () -> Void
  @State private var detection: CSVDetection?
  @State private var profileName = ""
  @State private var sourceKind: ImportSourceKind = .bankCSV
  @State private var dateColumn = 0
  @State private var amountColumn = 1
  @State private var descriptionColumn = 2
  @State private var externalIDColumn: Int?
  @State private var hasHeader = true
  @State private var loadError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading) {
          Text("入出金CSVを確認").font(.title2.bold())
          Text(sourceURL.lastPathComponent).foregroundStyle(.secondary)
        }
        Spacer()
        Button("閉じる", action: dismiss)
      }
      if let detection {
        Form {
          TextField("取込名", text: $profileName)
          Picker("種別", selection: $sourceKind) {
            Text("銀行CSV").tag(ImportSourceKind.bankCSV)
            Text("カードCSV").tag(ImportSourceKind.cardCSV)
            Text("汎用CSV").tag(ImportSourceKind.manualCSV)
          }
          Toggle("先頭行は見出し", isOn: $hasHeader)
          mappingPicker("日付", selection: $dateColumn, detection: detection)
          mappingPicker("金額", selection: $amountColumn, detection: detection)
          mappingPicker("摘要", selection: $descriptionColumn, detection: detection)
          Picker("外部ID", selection: $externalIDColumn) {
            Text("なし").tag(Int?.none)
            ForEach(0..<columnCount(detection), id: \.self) { index in
              Text(columnName(index, detection: detection)).tag(Int?.some(index))
            }
          }
        }
        .formStyle(.grouped)
        GroupBox("先頭行プレビュー") {
          ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
              ForEach(Array(detection.previewRows.prefix(8).enumerated()), id: \.offset) {
                index,
                row in
                GridRow {
                  Text("\(index + 1)").foregroundStyle(.secondary)
                  ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                    Text(value).lineLimit(1)
                  }
                }
              }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(6)
          }
          .frame(minHeight: 150)
        }
        HStack {
          Text("不正行と重複候補は隔離し、自動仕訳は行いません。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("候補として取り込む") {
            store.importCSV(
              from: sourceURL,
              profile: ImportProfile(
                name: profileName,
                sourceKind: sourceKind,
                encoding: detection.encoding,
                delimiter: detection.delimiter,
                hasHeader: hasHeader,
                mapping: ImportColumnMapping(
                  dateColumn: dateColumn,
                  amountColumn: amountColumn,
                  descriptionColumn: descriptionColumn,
                  externalIDColumn: externalIDColumn
                ),
                updatedAt: Date()
              )
            )
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } else if let loadError {
        ContentUnavailableView(
          "CSVを読み込めません",
          systemImage: "exclamationmark.triangle",
          description: Text(loadError)
        )
      } else {
        ProgressView("文字コードと区切り文字を確認しています")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(20)
    .frame(width: 820, height: 700)
    .onAppear(perform: load)
  }

  private func mappingPicker(
    _ title: String,
    selection: Binding<Int>,
    detection: CSVDetection
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(0..<columnCount(detection), id: \.self) { index in
        Text(columnName(index, detection: detection)).tag(index)
      }
    }
  }

  private func columnCount(_ detection: CSVDetection) -> Int {
    max(detection.previewRows.map(\.count).max() ?? 0, 1)
  }

  private func columnName(_ index: Int, detection: CSVDetection) -> String {
    if let first = detection.previewRows.first, first.indices.contains(index) {
      return "\(index + 1): \(first[index])"
    }
    return "\(index + 1)列目"
  }

  private func load() {
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
    do {
      let result = try CSVImporter.detect(Data(contentsOf: sourceURL))
      detection = result
      profileName = sourceURL.deletingPathExtension().lastPathComponent
      let count = columnCount(result)
      amountColumn = min(1, count - 1)
      descriptionColumn = min(2, count - 1)
      externalIDColumn = count > 3 ? 3 : nil
    } catch {
      loadError = "文字コード、区切り文字、読み取り権限を確認してください。"
    }
  }
}

private struct V2BooksView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var selectedAccountID: EntityID?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("帳簿").font(.largeTitle.bold())
      HStack {
        Text("借方合計 \(yen(store.trialBalance?.totalDebits.yen ?? 0))")
        Text("貸方合計 \(yen(store.trialBalance?.totalCredits.yen ?? 0))")
        Label(
          store.trialBalance?.isBalanced == true ? "貸借一致" : "要確認",
          systemImage: store.trialBalance?.isBalanced == true
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(store.trialBalance?.isBalanced == true ? .green : .orange)
      }
      Picker("元帳", selection: $selectedAccountID) {
        Text("仕訳帳").tag(EntityID?.none)
        ForEach(store.accounts) { Text($0.name).tag(EntityID?.some($0.id)) }
      }
      .frame(maxWidth: 300)

      if store.journalEntries.isEmpty {
        ContentUnavailableView(
          "仕訳はまだありません",
          systemImage: "book.closed",
          description: Text("日常処理で最初の仕訳を確定すると、仕訳帳と元帳を確認できます。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let accountID = selectedAccountID {
        let items = store.ledger(accountID: accountID)
        if items.isEmpty {
          ContentUnavailableView(
            "この科目の明細はありません",
            systemImage: "list.bullet.rectangle",
            description: Text("別の元帳を選択してください。")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Table(items) {
            TableColumn("日付") { Text($0.date.formatted(date: .numeric, time: .omitted)) }
            TableColumn("摘要", value: \.description)
            TableColumn("借方") { Text(yen($0.debit.yen)) }
            TableColumn("貸方") { Text(yen($0.credit.yen)) }
            TableColumn("残高") { Text(yen($0.runningBalance.yen)) }
          }
        }
      } else {
        Table(store.journalEntries) {
          TableColumn("日付") { Text($0.transactionDate.formatted(date: .numeric, time: .omitted)) }
          TableColumn("摘要", value: \.description)
          TableColumn("状態") { Text($0.status.v2LocalizedName) }
          TableColumn("金額") { entry in
            Text(yen((try? entry.totals().debits.yen) ?? 0))
          }
        }
      }
    }
    .padding(28)
  }
}

private struct V2ClosingView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var decisionType = ""
  @State private var rationale = ""
  @State private var amount = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("決算").font(.largeTitle.bold())
      if store.closingBlockers.isEmpty {
        ContentUnavailableView(
          "決算準備完了", systemImage: "checkmark.seal.fill", description: Text("帳簿と永続ジョブにブロッカーはありません。"))
      } else {
        GroupBox("ブロッカー") {
          ForEach(store.closingBlockers, id: \.self) {
            Label($0, systemImage: "exclamationmark.circle").padding(.vertical, 3)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      GroupBox("決算判断") {
        VStack(alignment: .leading, spacing: 10) {
          Form {
            TextField("判断項目", text: $decisionType)
            TextField("根拠", text: $rationale)
            TextField("金額（任意）", text: $amount)
            HStack {
              Button("未確認で保存") { saveDecision(state: .pending) }
              Button("内容を確認して確定") { saveDecision(state: .confirmed) }
                .buttonStyle(.borderedProminent)
            }
          }
          .formStyle(.grouped)
          ForEach(store.closingDecisions) { decision in
            HStack {
              VStack(alignment: .leading) {
                Text(decision.decisionType).font(.headline)
                Text(decision.rationale).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(decision.state.v2LocalizedName)
              if let amount = decision.amountYen { Text(yen(amount)).monospacedDigit() }
            }
            Divider()
          }
        }
        .padding(6)
      }
      Spacer()
    }
    .padding(28)
  }

  private func saveDecision(state: ClosingDecisionStateV2) {
    store.saveClosingDecision(
      type: decisionType,
      rationale: rationale,
      amountYen: Int64(amount),
      state: state
    )
    decisionType = ""
    rationale = ""
    amount = ""
  }
}

private struct V2FilingView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var postalAddress = ""
  @State private var taxAddress = ""
  @State private var taxOffice = ""
  @State private var taxOfficeCode = ""
  @State private var eTaxUserID = ""
  @State private var exportDocument: V2XTXDocument?
  @State private var exporting = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("申告").font(.largeTitle.bold())
        if store.isFilingSupported {
          Label(
            "署名検証済みの所得税帳票・XTXルールが利用できます。",
            systemImage: "checkmark.shield"
          )
          .foregroundStyle(.green)
        } else {
          ContentUnavailableView(
            "この年度の申告出力は未提供です",
            systemImage: "doc.badge.clock",
            description: Text(
              "最終様式、e-Tax仕様、実際のe-Tax WEB読込とPDF全項目照合が完了するまで出力を有効化しません。"
            )
          )
        }
        if let support = store.yearSupport {
          GroupBox("年度ルール") {
            ForEach(RuleScope.allCases, id: \.self) { scope in
              HStack {
                Text(scope.v2LocalizedName)
                Spacer()
                Image(
                  systemName: support.supports(scope)
                    ? "checkmark.circle.fill" : "minus.circle"
                )
                .foregroundStyle(support.supports(scope) ? .green : .secondary)
              }
            }
            .padding(6)
          }
        }

        if store.isFilingSupported {
          GroupBox("申告者情報") {
            Form {
              TextField("住所", text: $postalAddress)
              TextField("納税地（住所と同じ場合は空欄可）", text: $taxAddress)
              TextField("提出先税務署", text: $taxOffice)
              TextField("税務署番号（5桁）", text: $taxOfficeCode)
              TextField("e-Tax利用者識別番号（16桁）", text: $eTaxUserID)
              HStack {
                Spacer()
                Button("申告者情報を保存") {
                  store.saveFilingIdentity(
                    postalAddress: postalAddress,
                    taxAddress: taxAddress,
                    taxOffice: taxOffice,
                    taxOfficeCode: taxOfficeCode,
                    eTaxUserID: eTaxUserID
                  )
                }
                .disabled(store.isWorking)
              }
            }
            .formStyle(.grouped)
          }

          if !store.filingBlockers.isEmpty {
            GroupBox("出力前の確認") {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(store.filingBlockers, id: \.self) {
                  Label($0, systemImage: "exclamationmark.circle")
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6)
            }
          }

          GroupBox("XTX出力") {
            VStack(alignment: .leading, spacing: 10) {
              Text("生成は永続ジョブとして記録し、同じ帳簿・申告者情報では重複生成しません。")
                .foregroundStyle(.secondary)
              Button("確認してXTXを生成") {
                Task {
                  guard let package = await store.generateXTXPackage() else { return }
                  exportDocument = V2XTXDocument(data: package.data)
                  exporting = true
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(!store.filingBlockers.isEmpty || store.isWorking)
              .accessibilityHint("検証済み申告データからXTXを生成し、保存先を選択します")
              if let status = store.xtxStatus {
                Text(status).font(.caption).textSelection(.enabled)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
          }
        }
      }
      .padding(28)
    }
    .onAppear(perform: loadProfile)
    .fileExporter(
      isPresented: $exporting,
      document: exportDocument,
      contentType: .blueprintXTX,
      defaultFilename: "blue-print-\(store.fiscalYear?.calendarYear ?? 0).xtx"
    ) { result in
      if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
      exportDocument = nil
    }
  }

  private func loadProfile() {
    guard let profile = store.profile else { return }
    postalAddress = profile.postalAddress
    taxAddress = profile.taxAddress
    taxOffice = profile.taxOffice
    taxOfficeCode = profile.taxOfficeCode
    eTaxUserID = profile.eTaxUserID
  }
}

private struct V2UtilitiesView: View {
  @ObservedObject var store: V2WorkspaceStore
  @State private var passphrase = ""
  @State private var backupDocument: V2BackupDocument?
  @State private var exporting = false
  @State private var importingBackup = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("設定・データ管理").font(.largeTitle.bold())

        GroupBox("暗号化バックアップ") {
          VStack(alignment: .leading, spacing: 10) {
            SecureField("12文字以上のパスフレーズ", text: $passphrase)
            Button("v2バックアップを書き出す") {
              Task {
                do {
                  backupDocument = V2BackupDocument(
                    data: try await store.makeEncryptedBackup(passphrase: passphrase)
                  )
                  exporting = true
                } catch {
                  store.errorMessage = error.localizedDescription
                }
              }
            }
            .disabled(passphrase.count < 12 || store.isWorking)
            Button("v2バックアップを復元") { importingBackup = true }
              .disabled(passphrase.count < 12 || store.isWorking)
            Text("v1バックアップは受け付けません。Argon2id v19 + AES-256-GCMを使用します。")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let restoreStatus = store.restoreStatus {
              Text(restoreStatus).font(.caption).textSelection(.enabled)
            }
          }
          .padding(6)
        }

        GroupBox("診断と修復") {
          VStack(alignment: .leading, spacing: 10) {
            Button("読み取り専用診断を実行") { store.runDiagnostics() }
            if let report = store.diagnosticReport {
              Text("\(report.findings.count)件の所見・証憑\(report.evidenceChecked)件を確認")
              ForEach(report.findings) { finding in
                Label(
                  "\(finding.title)：\(finding.detail)",
                  systemImage: finding.severity == .error
                    ? "xmark.octagon" : "exclamationmark.triangle"
                )
              }
              if report.findings.isEmpty {
                Label("問題は見つかりませんでした", systemImage: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
              if report.findings.contains(where: { $0.repairKind != nil }) {
                Button("暗号化バックアップを作成して修復内容をプレビュー") {
                  store.prepareRepairWithBackup(passphrase: passphrase)
                }
                .disabled(passphrase.count < 12)
                .accessibilityHint("修復はまだ実行せず、バックアップと変更内容のプレビューだけを作成します")
              }
            }
            if let plan = store.repairPlan {
              Divider()
              Text("修復プレビュー").font(.headline)
              Text("バックアップ先: \(plan.backupURL.path)")
                .font(.caption)
                .textSelection(.enabled)
              ForEach(plan.changes) { change in
                Text("・\(change.summary)（\(change.affectedRecordCount)件）")
              }
              Button("表示内容で修復を実行") { store.applyRepairPlan() }
                .buttonStyle(.borderedProminent)
                .disabled(plan.state != .previewed)
                .accessibilityHint("表示中の変更を単一トランザクションで適用します")
            }
            Text("修復は影響件数とバックアップ先をプレビューし、バックアップ成功後の単一トランザクションでだけ実行されます。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(6)
        }

        GroupBox("監査履歴") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(store.auditEvents.prefix(20)) { event in
              HStack {
                Text(event.occurredAt.formatted(date: .numeric, time: .shortened))
                  .monospacedDigit()
                Text(event.action.localizedName)
                Text(v2AuditTargetName(event.targetType))
                Spacer()
                Text(event.targetID.prefix(8)).foregroundStyle(.secondary)
              }
              .font(.caption)
            }
            if store.auditEvents.isEmpty {
              Text("監査イベントはありません。").foregroundStyle(.secondary)
            }
          }
          .padding(6)
        }

        GroupBox("バージョン") {
          VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading) {
              GridRow {
                Text("アプリ")
                Text(BlueprintVersions.app)
              }
              GridRow {
                Text("保存世代")
                Text("\(BlueprintVersions.storageGeneration)")
              }
              GridRow {
                Text("DB schema")
                Text("\(BlueprintVersions.databaseSchema)")
              }
              GridRow {
                Text("バックアップ")
                Text("\(BlueprintVersions.backupFamily) v\(BlueprintVersions.backupFormat)")
              }
            }
            Button("更新を確認") { store.checkForUpdates() }
            if let updateStatus = store.updateStatus {
              Text(updateStatus).font(.caption).textSelection(.enabled)
            }
            Text("このボタンを押した時だけ通信します。バックグラウンド確認、テレメトリ、自動置換は行いません。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(6)
        }
      }
      .padding(28)
    }
    .fileExporter(
      isPresented: $exporting,
      document: backupDocument,
      contentType: .blueprintV2Backup,
      defaultFilename: "BluePrint-v2-\(store.fiscalYear?.calendarYear ?? 0).bpv2backup"
    ) { result in
      if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
      backupDocument = nil
    }
    .fileImporter(
      isPresented: $importingBackup,
      allowedContentTypes: [.blueprintV2Backup],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          store.stageEncryptedRestore(from: url, passphrase: passphrase)
        }
      case .failure(let error):
        store.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct V2MetricCard: View {
  let title: String
  let value: Int
  let detail: String
  let symbol: String

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol).font(.headline)
        Text("\(value)").font(.system(size: 32, weight: .bold, design: .rounded))
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)、\(value)、\(detail)")
  }
}

private struct V2BackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.blueprintV2Backup] }
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct V2XTXDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.blueprintXTX] }
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension UTType {
  fileprivate static let blueprintV2Backup = UTType(
    exportedAs: "com.ryo1280.blueprint.v2-backup",
    conformingTo: .data
  )
  fileprivate static let blueprintXTX = UTType(filenameExtension: "xtx") ?? .xml
}

private func yen(_ value: Int64) -> String {
  value.formatted(.currency(code: "JPY").precision(.fractionLength(0)))
}

private func v2AuditTargetName(_ value: String) -> String {
  switch value {
  case "BusinessProfile": "事業者情報"
  case "FiscalYear": "年度"
  case "JournalEntry": "仕訳"
  case "EvidenceDocument": "証憑"
  case "Counterparty": "取引先"
  case "Invoice": "請求書"
  case "ClosingDecision": "決算判断"
  default: value
  }
}
