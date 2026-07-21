import AppKit
import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum InboxMode: String, CaseIterable, Identifiable {
  case evidence = "証憑"
  case statements = "明細"

  var id: String { rawValue }
}

private enum InboxFilter: String, CaseIterable, Identifiable {
  case all = "すべて"
  case unprocessed = "未処理"
  case needsReview = "確認待ち"
  case posted = "転記済み"
  case excluded = "対象外"

  var id: String { rawValue }

  var evidenceState: EvidenceState? {
    switch self {
    case .all: nil
    case .unprocessed: .unprocessed
    case .needsReview: .needsReview
    case .posted: .posted
    case .excluded: .excluded
    }
  }

  var transactionState: ImportedTransactionState? {
    switch self {
    case .all: nil
    case .unprocessed: .unprocessed
    case .needsReview: .needsReview
    case .posted: .posted
    case .excluded: .excluded
    }
  }
}

struct EvidenceInboxView: View {
  @ObservedObject var model: AppModel
  @State private var mode: InboxMode = .evidence
  @State private var filter: InboxFilter = .all
  @State private var query = ""
  @State private var selectedEvidenceID: EntityID?
  @State private var selectedTransactionID: EntityID?
  @State private var showingEvidenceImporter = false
  @State private var showingCSVImporter = false
  @State private var csvURL: URL?

  private var evidenceDocuments: [EvidenceDocument] {
    model.evidenceDocuments.filter { document in
      (filter.evidenceState == nil || document.state == filter.evidenceState)
        && (query.isEmpty
          || document.originalFilename.localizedCaseInsensitiveContains(query)
          || (document.counterparty?.localizedCaseInsensitiveContains(query) ?? false)
          || String(document.amount?.yen ?? 0).contains(query))
    }
  }

  private var transactions: [ImportedTransaction] {
    model.importedTransactions.filter { transaction in
      (filter.transactionState == nil || transaction.state == filter.transactionState)
        && (query.isEmpty
          || transaction.description.localizedCaseInsensitiveContains(query)
          || String(transaction.amount.yen).contains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      inboxHeader
      Divider()
      HSplitView {
        inboxList
          .frame(minWidth: 330, idealWidth: 390, maxWidth: 480)
        detailPane
          .frame(minWidth: 560)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .fileImporter(
      isPresented: $showingEvidenceImporter,
      allowedContentTypes: [.pdf, .png, .jpeg, .heic, .tiff],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        model.importEvidence(from: url, origin: .electronicTransaction)
        selectedEvidenceID = model.evidenceDocuments.first?.id
      }
    }
    .fileImporter(
      isPresented: $showingCSVImporter,
      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result { csvURL = urls.first }
    }
    .sheet(
      isPresented: Binding(
        get: { csvURL != nil },
        set: { if !$0 { csvURL = nil } }
      )
    ) {
      if let csvURL {
        CSVImportSheet(model: model, sourceURL: csvURL) { self.csvURL = nil }
      }
    }
    .onAppear {
      if selectedEvidenceID == nil { selectedEvidenceID = evidenceDocuments.first?.id }
      if selectedTransactionID == nil { selectedTransactionID = transactions.first?.id }
    }
  }

  private var inboxHeader: some View {
    VStack(spacing: 14) {
      HStack(alignment: .center, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("受信箱")
            .font(.system(size: 28, weight: .semibold))
          Text("原本を見ながら候補を確認し、人の判断で仕訳へ転記します。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("取込種別", selection: $mode) {
          ForEach(InboxMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        Button("明細を読み込む", systemImage: "tablecells") {
          showingCSVImporter = true
        }
        Button("証憑を取り込む", systemImage: "square.and.arrow.down") {
          showingEvidenceImporter = true
        }
        .buttonStyle(.borderedProminent)
      }
      HStack(spacing: 12) {
        Picker("状態", selection: $filter) {
          ForEach(InboxFilter.allCases) { item in
            Text("\(item.rawValue) \(count(for: item))").tag(item)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        TextField("ファイル名・取引先・金額を検索", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 320)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  @ViewBuilder
  private var inboxList: some View {
    switch mode {
    case .evidence:
      List(evidenceDocuments, selection: $selectedEvidenceID) { document in
        EvidenceInboxRow(document: document)
          .tag(document.id)
      }
      .listStyle(.inset)
      .overlay {
        if evidenceDocuments.isEmpty {
          ContentUnavailableView(
            "証憑はありません",
            systemImage: "doc.text.magnifyingglass",
            description: Text("証憑を取り込むと、原本とOCR候補を並べて確認できます。")
          )
        }
      }
    case .statements:
      VStack(spacing: 0) {
        List(transactions, selection: $selectedTransactionID) { transaction in
          TransactionInboxRow(transaction: transaction)
            .tag(transaction.id)
        }
        .listStyle(.inset)
        .overlay {
          if transactions.isEmpty {
            ContentUnavailableView(
              "明細はありません",
              systemImage: "tablecells",
              description: Text("銀行・カードCSVを読み込むと、正常行と隔離行を確認できます。")
            )
          }
        }
        if let latestBatch = model.importBatches.first {
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(latestBatch.sourceFilename).font(.caption.weight(.semibold))
              Text("正常 \(latestBatch.transactions.count)件・隔離 \(latestBatch.errors.count)件")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取込を取消") { model.cancelImportBatch(latestBatch) }
              .disabled(latestBatch.state == .cancelled)
          }
          .padding(12)
          .background(Color(nsColor: .controlBackgroundColor))
        }
      }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    switch mode {
    case .evidence:
      if let document = model.evidenceDocuments.first(where: { $0.id == selectedEvidenceID }) {
        EvidenceReviewPane(model: model, document: document)
          .id(document.id.uuidString + document.state.rawValue)
          .modifier(QADetailAccessibilityModifier())
      } else {
        InboxEmptyDetail(title: "証憑を選択", subtitle: "左の一覧から確認する原本を選んでください。")
      }
    case .statements:
      if let transaction = model.importedTransactions.first(where: {
        $0.id == selectedTransactionID
      }) {
        TransactionReviewPane(model: model, transaction: transaction)
      } else {
        InboxEmptyDetail(title: "明細を選択", subtitle: "左の一覧から確認する取引を選んでください。")
      }
    }
  }

  private func count(for item: InboxFilter) -> Int {
    switch mode {
    case .evidence:
      guard let state = item.evidenceState else { return model.evidenceDocuments.count }
      return model.evidenceDocuments.filter { $0.state == state }.count
    case .statements:
      guard let state = item.transactionState else { return model.importedTransactions.count }
      return model.importedTransactions.filter { $0.state == state }.count
    }
  }
}

private struct QADetailAccessibilityModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    #if DEBUG
      if ProcessInfo.processInfo.environment["BLUEPRINT_QA_HIDE_DETAIL_AX"] == "1" {
        content.accessibilityHidden(true)
      } else {
        content
      }
    #else
      content
    #endif
  }
}

private struct EvidenceInboxRow: View {
  let document: EvidenceDocument

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: document.mimeType == "application/pdf" ? "doc.richtext" : "photo")
        .font(.title3)
        .foregroundStyle(.indigo)
        .frame(width: 28, height: 32)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(document.counterparty ?? document.originalFilename)
            .font(.headline)
            .lineLimit(1)
          Spacer()
          EvidenceStatusBadge(state: document.state)
        }
        HStack {
          Text(
            document.transactionDate ?? document.acquiredAt, format: .dateTime.year().month().day())
          Spacer()
          Text(
            (document.amount?.yen ?? 0).formatted(
              .currency(code: "JPY").precision(.fractionLength(0)))
          )
          .fontWeight(.semibold)
          .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(document.originalFilename)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 7)
  }
}

private struct TransactionInboxRow: View {
  let transaction: ImportedTransaction

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(transaction.description).font(.headline).lineLimit(1)
        Spacer()
        Text(transaction.state.localizedName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(transaction.state == .posted ? .green : .orange)
      }
      HStack {
        Text(transaction.transactionDate, format: .dateTime.year().month().day())
        Spacer()
        Text(transaction.amount.yen, format: .currency(code: "JPY").precision(.fractionLength(0)))
          .fontWeight(.semibold)
          .monospacedDigit()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if transaction.duplicateOfID != nil {
        Label("重複候補", systemImage: "doc.on.doc")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 7)
  }
}

private struct EvidenceReviewPane: View {
  @ObservedObject var model: AppModel
  let document: EvidenceDocument
  @State private var transactionDate: Date
  @State private var amountText: String
  @State private var counterparty: String
  @State private var descriptionText: String
  @State private var expenseAccountID: EntityID?
  @State private var paymentAccountID: EntityID?
  @State private var taxSelection: TaxSelection = .standard10Qualified
  @State private var roundingUnit: RoundingUnit = .line

  init(model: AppModel, document: EvidenceDocument) {
    self.model = model
    self.document = document
    _transactionDate = State(initialValue: document.transactionDate ?? document.acquiredAt)
    _amountText = State(initialValue: document.amount.map { String($0.yen) } ?? "")
    _counterparty = State(initialValue: document.counterparty ?? "")
    _descriptionText = State(initialValue: document.counterparty.map { "\($0) 支払" } ?? "")
  }

  private var candidates: [OCRCandidate] { model.evidenceCandidates(evidenceID: document.id) }
  private var isPosted: Bool { document.state == .posted }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("原本プレビュー").font(.headline)
            Text(
              "\(document.origin.localizedName)・\(ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Label("原本保護", systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.indigo)
        }
        .padding(16)
        Divider()
        EvidencePreview(url: model.originalURL(for: document), mimeType: document.mimeType)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(nsColor: .underPageBackgroundColor))
          .accessibilityHidden(true)
        Divider()
        Text("SHA-256  \(document.originalSHA256.prefix(18))…")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(minWidth: 300, idealWidth: 410)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("仕訳候補を確認")
                .font(.title2.weight(.semibold))
              Text("OCR候補は自動転記されません。原本と照合してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            EvidenceStatusBadge(state: document.state)
          }

          GroupBox("取引情報") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
              reviewRow("取引日", confidence: confidence(.transactionDate)) {
                DatePicker("取引日", selection: $transactionDate, displayedComponents: .date)
                  .labelsHidden()
              }
              reviewRow("金額", confidence: confidence(.amount)) {
                TextField("0", text: $amountText)
                  .multilineTextAlignment(.trailing)
                  .frame(width: 160)
              }
              reviewRow("取引先", confidence: confidence(.counterparty)) {
                TextField("取引先", text: $counterparty)
              }
              reviewRow("摘要", confidence: nil) {
                TextField("摘要", text: $descriptionText)
              }
            }
            .padding(.top, 6)
          }

          GroupBox("仕訳と税区分") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
              GridRow {
                Text("費用科目").foregroundStyle(.secondary)
                Picker("費用科目", selection: $expenseAccountID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(model.accounts.filter { $0.isActive && $0.category == .expense }) {
                    Text("\($0.code)  \($0.name)").tag(Optional($0.id))
                  }
                }
                .labelsHidden()
              }
              GridRow {
                Text("支払科目").foregroundStyle(.secondary)
                Picker("支払科目", selection: $paymentAccountID) {
                  Text("選択").tag(EntityID?.none)
                  ForEach(model.accounts.filter { $0.isActive && $0.category == .asset }) {
                    Text("\($0.code)  \($0.name)").tag(Optional($0.id))
                  }
                }
                .labelsHidden()
              }
              GridRow {
                Text("税区分").foregroundStyle(.secondary)
                Picker("税区分", selection: $taxSelection) {
                  ForEach(TaxSelection.allCases, id: \.self) { selection in
                    Text(selection.localizedName).tag(selection)
                  }
                }
                .labelsHidden()
              }
              GridRow {
                Text("端数処理").foregroundStyle(.secondary)
                Picker("端数処理", selection: $roundingUnit) {
                  Text("明細単位").tag(RoundingUnit.line)
                  Text("伝票単位").tag(RoundingUnit.voucher)
                }
                .labelsHidden()
              }
            }
            .padding(.top, 6)
          }

          if !candidates.isEmpty {
            DisclosureGroup("OCR候補と修正履歴（\(candidates.count)件）") {
              VStack(spacing: 8) {
                ForEach(candidates) { candidate in
                  OCRCandidateRow(model: model, candidate: candidate)
                }
              }
              .padding(.top, 8)
            }
          }

          HStack {
            Button("対象外にする", role: .destructive) { model.excludeEvidence(document) }
              .disabled(isPosted)
            Spacer()
            Button(isPosted ? "転記済み" : "確認して仕訳へ転記") { confirm() }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(!canConfirm || isPosted)
          }
        }
        .padding(20)
      }
      .frame(minWidth: 360, idealWidth: 460)
    }
    .onAppear {
      expenseAccountID =
        expenseAccountID
        ?? model.accounts.first { $0.isActive && $0.category == .expense }?.id
      paymentAccountID =
        paymentAccountID
        ?? model.accounts.first { $0.isActive && $0.category == .asset }?.id
    }
  }

  private var canConfirm: Bool {
    (Int64(amountText.replacingOccurrences(of: ",", with: "")) ?? 0) > 0
      && !counterparty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && expenseAccountID != nil && paymentAccountID != nil
  }

  private func confidence(_ field: OCRField) -> Double? {
    candidates.filter { $0.field == field }.map(\.confidence).max()
  }

  private func reviewRow<Content: View>(
    _ label: String,
    confidence: Double?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GridRow {
      HStack(spacing: 6) {
        Text(label).foregroundStyle(.secondary)
        if let confidence { ConfidenceBadge(value: confidence) }
      }
      content()
    }
  }

  private func confirm() {
    guard let amount = Int64(amountText.replacingOccurrences(of: ",", with: "")),
      let expenseAccountID,
      let paymentAccountID
    else { return }
    model.confirmEvidence(
      document,
      transactionDate: transactionDate,
      amount: Money(yen: amount),
      counterparty: counterparty,
      description: descriptionText,
      expenseAccountID: expenseAccountID,
      paymentAccountID: paymentAccountID,
      taxSelection: taxSelection,
      roundingUnit: roundingUnit
    )
  }
}

private struct TransactionReviewPane: View {
  @ObservedObject var model: AppModel
  let transaction: ImportedTransaction
  @State private var selectedEvidenceID: EntityID?
  @State private var expenseAccountID: EntityID?
  @State private var paymentAccountID: EntityID?
  @State private var taxSelection: TaxSelection = .standard10Qualified
  @State private var roundingUnit: RoundingUnit = .line

  init(model: AppModel, transaction: ImportedTransaction) {
    self.model = model
    self.transaction = transaction
    _selectedEvidenceID = State(initialValue: transaction.evidenceID)
  }

  private var candidates: [TransactionEvidenceCandidate] {
    model.transactionEvidenceCandidates(transactionID: transaction.id)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("明細を確認")
            .font(.title2.weight(.semibold))
          Text("CSVの値を確認し、証憑候補との一致を見てから仕訳候補を作成します。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(transaction.state.localizedName)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(.orange.opacity(0.12), in: Capsule())
      }
      GroupBox("取込内容") {
        LabeledContent(
          "取引日", value: transaction.transactionDate.formatted(date: .long, time: .omitted))
        LabeledContent(
          "金額",
          value: transaction.amount.yen.formatted(
            .currency(code: "JPY").precision(.fractionLength(0))))
        LabeledContent("摘要", value: transaction.description)
        LabeledContent("外部ID", value: transaction.externalID ?? "—")
      }
      GroupBox("証憑の関連付け") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Image(
              systemName: transaction.evidenceID == nil ? "link.badge.plus" : "link.circle.fill"
            )
            .foregroundStyle(.indigo)
            Text(transaction.evidenceID == nil ? "日付・金額・取引先から候補を照合しました" : "証憑を関連付け済みです")
            Spacer()
          }
          if candidates.isEmpty && transaction.evidenceID == nil {
            Text("一致する証憑候補はありません。先に証憑を取り込んでください。")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            HStack {
              Picker("証憑候補", selection: $selectedEvidenceID) {
                Text("選択").tag(EntityID?.none)
                ForEach(candidates) { candidate in
                  let document = model.evidenceDocuments.first { $0.id == candidate.evidenceID }
                  Text(
                    "\(document?.counterparty ?? document?.originalFilename ?? "証憑")・\(Int(candidate.score * 100))%"
                  )
                  .tag(Optional(candidate.evidenceID))
                }
              }
              Button("関連付ける") {
                if let selectedEvidenceID {
                  model.associateEvidence(
                    transactionID: transaction.id,
                    evidenceID: selectedEvidenceID
                  )
                }
              }
              .disabled(selectedEvidenceID == nil || transaction.evidenceID != nil)
            }
          }
        }
      }
      GroupBox("仕訳と税区分") {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("費用科目")
            Picker("費用科目", selection: $expenseAccountID) {
              Text("選択").tag(EntityID?.none)
              ForEach(model.accounts.filter { $0.isActive && $0.category == .expense }) {
                Text("\($0.code)  \($0.name)").tag(Optional($0.id))
              }
            }.labelsHidden()
          }
          GridRow {
            Text("支払科目")
            Picker("支払科目", selection: $paymentAccountID) {
              Text("選択").tag(EntityID?.none)
              ForEach(model.accounts.filter { $0.isActive && $0.category == .asset }) {
                Text("\($0.code)  \($0.name)").tag(Optional($0.id))
              }
            }.labelsHidden()
          }
          GridRow {
            Text("税区分")
            Picker("税区分", selection: $taxSelection) {
              ForEach(TaxSelection.allCases, id: \.self) {
                Text($0.localizedName).tag($0)
              }
            }.labelsHidden()
          }
          GridRow {
            Text("端数処理")
            Picker("端数処理", selection: $roundingUnit) {
              Text("明細単位").tag(RoundingUnit.line)
              Text("伝票単位").tag(RoundingUnit.voucher)
            }.labelsHidden()
          }
        }
        .padding(.top, 6)
      }
      if let batch = model.importBatches.first(where: { $0.id == transaction.batchID }),
        !batch.errors.isEmpty
      {
        GroupBox("隔離された行") {
          ForEach(batch.errors) { error in
            LabeledContent("\(error.rowNumber)行目", value: error.message)
          }
        }
      }
      Spacer()
      HStack {
        Label("外部通信なし・ローカル処理", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(transaction.state == .posted ? "転記済み" : "確認して仕訳へ転記") {
          if let expenseAccountID, let paymentAccountID {
            model.confirmImportedTransaction(
              transaction,
              expenseAccountID: expenseAccountID,
              paymentAccountID: paymentAccountID,
              taxSelection: taxSelection,
              roundingUnit: roundingUnit
            )
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          transaction.state == .posted || transaction.state == .excluded
            || expenseAccountID == nil || paymentAccountID == nil)
      }
    }
    .padding(28)
    .onAppear {
      expenseAccountID =
        expenseAccountID
        ?? model.accounts.first { $0.isActive && $0.category == .expense }?.id
      paymentAccountID =
        paymentAccountID
        ?? model.accounts.first { $0.isActive && $0.category == .asset }?.id
      selectedEvidenceID = selectedEvidenceID ?? candidates.first?.evidenceID
    }
  }
}

private struct OCRCandidateRow: View {
  @ObservedObject var model: AppModel
  let candidate: OCRCandidate
  @State private var value: String

  init(model: AppModel, candidate: OCRCandidate) {
    self.model = model
    self.candidate = candidate
    _value = State(initialValue: candidate.effectiveValue)
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(candidate.field.localizedName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 74, alignment: .leading)
      TextField("候補値", text: $value)
      ConfidenceBadge(value: candidate.confidence)
      Button("修正を記録") {
        model.correctOCRCandidate(candidate, value: value)
      }
      .disabled(value == candidate.effectiveValue || value.isEmpty)
    }
  }
}

private struct ConfidenceBadge: View {
  let value: Double

  var body: some View {
    Text("\(Int(value * 100))%")
      .font(.caption2.monospacedDigit().weight(.semibold))
      .foregroundStyle(value >= 0.9 ? .green : value >= 0.75 ? .orange : .red)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
  }
}

private struct EvidenceStatusBadge: View {
  let state: EvidenceState

  var body: some View {
    Text(state.localizedName)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.1), in: Capsule())
  }

  private var color: Color {
    switch state {
    case .unprocessed: .secondary
    case .needsReview: .orange
    case .posted: .green
    case .excluded: .red
    }
  }
}

private struct EvidencePreview: View {
  let url: URL?
  let mimeType: String

  var body: some View {
    Group {
      if let url, mimeType == "application/pdf" {
        PDFPreview(url: url)
      } else if let url, let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(22)
      } else {
        ContentUnavailableView("プレビューできません", systemImage: "doc")
      }
    }
  }
}

private struct PDFPreview: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displaysPageBreaks = true
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
  }
}

private struct InboxEmptyDetail: View {
  let title: String
  let subtitle: String

  var body: some View {
    ContentUnavailableView(title, systemImage: "sidebar.right", description: Text(subtitle))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct CSVImportSheet: View {
  @ObservedObject var model: AppModel
  let sourceURL: URL
  let dismiss: () -> Void
  @State private var data: Data?
  @State private var detection: CSVDetection?
  @State private var profileName = ""
  @State private var sourceKind: ImportSourceKind = .bankCSV
  @State private var dateColumn = 0
  @State private var amountColumn = 1
  @State private var descriptionColumn = 2
  @State private var externalIDColumn = 3
  @State private var loadError: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("明細CSVを確認")
            .font(.title2.weight(.semibold))
          Text(sourceURL.lastPathComponent)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("閉じる", action: dismiss)
      }
      .padding(20)
      Divider()
      if let detection {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 14) {
            Label(detection.encoding.localizedName, systemImage: "textformat")
            Label(detection.delimiter.localizedName, systemImage: "tablecells")
            Spacer()
            Text("先頭 \(detection.previewRows.count)行をプレビュー")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          GroupBox("取込プロファイル") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
              GridRow {
                Text("名前")
                TextField("例：青空銀行 普通預金", text: $profileName)
              }
              GridRow {
                Text("種別")
                Picker("種別", selection: $sourceKind) {
                  Text("銀行CSV").tag(ImportSourceKind.bankCSV)
                  Text("カードCSV").tag(ImportSourceKind.cardCSV)
                  Text("汎用CSV").tag(ImportSourceKind.manualCSV)
                }
                .labelsHidden()
              }
              mappingRow("日付", selection: $dateColumn, detection: detection)
              mappingRow("金額", selection: $amountColumn, detection: detection)
              mappingRow("摘要", selection: $descriptionColumn, detection: detection)
              mappingRow("外部ID", selection: $externalIDColumn, detection: detection)
            }
            .padding(.top, 6)
          }
          GroupBox("プレビュー") {
            ScrollView([.horizontal, .vertical]) {
              Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(Array(detection.previewRows.enumerated()), id: \.offset) { index, row in
                  GridRow {
                    Text("\(index + 1)")
                      .foregroundStyle(.secondary)
                      .monospacedDigit()
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                      Text(value).lineLimit(1)
                    }
                  }
                  if index == 0 { Divider() }
                }
              }
              .font(.system(size: 13, design: .monospaced))
              .padding(8)
            }
            .frame(minHeight: 220)
          }
          Spacer()
          HStack {
            Text("不正行は隔離し、正常行だけを保存します。")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("取込を実行") { performImport(detection) }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding(20)
      } else if let loadError {
        ContentUnavailableView(
          "CSVを読み込めません", systemImage: "exclamationmark.triangle", description: Text(loadError))
      } else {
        ProgressView("文字コードと区切り文字を判定しています")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 820, height: 700)
    .onAppear(perform: load)
  }

  private func mappingRow(
    _ label: String,
    selection: Binding<Int>,
    detection: CSVDetection
  ) -> some View {
    GridRow {
      Text(label)
      Picker(label, selection: selection) {
        ForEach(0..<maxColumnCount(detection), id: \.self) { index in
          Text(columnName(index, detection: detection)).tag(index)
        }
      }
      .labelsHidden()
    }
  }

  private func maxColumnCount(_ detection: CSVDetection) -> Int {
    max(detection.previewRows.map(\.count).max() ?? 0, 1)
  }

  private func columnName(_ index: Int, detection: CSVDetection) -> String {
    if let header = detection.previewRows.first, header.indices.contains(index) {
      return "\(index + 1): \(header[index])"
    }
    return "\(index + 1)列目"
  }

  private func load() {
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: sourceURL)
      self.data = data
      let detection = try CSVImporter.detect(data)
      self.detection = detection
      profileName = sourceURL.deletingPathExtension().lastPathComponent
      let count = maxColumnCount(detection)
      externalIDColumn = min(3, count - 1)
    } catch {
      loadError = "ファイルの文字コード、区切り文字、読み取り権限を確認してください。"
    }
  }

  private func performImport(_ detection: CSVDetection) {
    guard let data else { return }
    let profile = ImportProfile(
      name: profileName,
      sourceKind: sourceKind,
      encoding: detection.encoding,
      delimiter: detection.delimiter,
      hasHeader: true,
      mapping: ImportColumnMapping(
        dateColumn: dateColumn,
        amountColumn: amountColumn,
        descriptionColumn: descriptionColumn,
        externalIDColumn: externalIDColumn
      ),
      updatedAt: Date()
    )
    model.importCSV(data: data, filename: sourceURL.lastPathComponent, profile: profile)
    if model.errorMessage == nil { dismiss() }
  }
}
