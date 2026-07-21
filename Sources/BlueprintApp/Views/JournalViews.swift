import BlueprintDomain
import SwiftUI

private struct DraftJournalLine: Identifiable {
  let id = UUID()
  var accountID: EntityID?
  var side: PostingSide
  var amountText = ""
  var taxRate: TaxRate = .outOfScope
  var counterparty = ""
  var memo = ""
}

struct JournalEntryView: View {
  @ObservedObject var model: AppModel
  @State private var transactionDate = Date()
  @State private var description = ""
  @State private var rows = [
    DraftJournalLine(side: .debit),
    DraftJournalLine(side: .credit),
  ]

  private var difference: Int64 {
    rows.reduce(0) { partial, row in
      let amount = Int64(row.amountText.replacingOccurrences(of: ",", with: "")) ?? 0
      return partial + (row.side == .debit ? amount : -amount)
    }
  }

  private var canPost: Bool {
    rows.count >= 2 && rows.allSatisfy { $0.accountID != nil && amount(of: $0) > 0 }
      && difference == 0 && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("取引入力")
            .font(.system(size: 30, weight: .semibold))
          Text("貸借を確認してから記帳します。転記後は削除せず、取消・訂正で履歴を残します。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        DatePicker("取引日", selection: $transactionDate, displayedComponents: .date)
          .labelsHidden()
      }
      .padding(32)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        HStack {
          TextField("摘要（例：成城石井 食材）", text: $description)
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .accessibilityLabel("摘要")
          Menu("摘要候補") {
            ForEach(Array(Set(model.journalEntries.map(\.description))).sorted(), id: \.self) {
              candidate in
              Button(candidate) { description = candidate }
            }
          }
          .disabled(model.journalEntries.isEmpty)
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("貸借").frame(width: 64, alignment: .leading)
            Text("勘定科目").frame(minWidth: 180, alignment: .leading)
            Text("金額").frame(width: 130, alignment: .trailing)
            Text("税区分").frame(width: 110, alignment: .leading)
            Text("取引先・メモ").frame(minWidth: 220, alignment: .leading)
            Color.clear.frame(width: 24)
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

          ForEach($rows) { $row in
            GridRow {
              Picker("貸借", selection: $row.side) {
                Text("借方").tag(PostingSide.debit)
                Text("貸方").tag(PostingSide.credit)
              }
              .labelsHidden()
              .frame(width: 64)

              Picker("勘定科目", selection: $row.accountID) {
                Text("選択").tag(EntityID?.none)
                ForEach(model.accounts.filter(\.isActive)) { account in
                  Text("\(account.code)  \(account.name)").tag(Optional(account.id))
                }
              }
              .labelsHidden()
              .frame(minWidth: 180)

              TextField("0", text: $row.amountText)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .accessibilityLabel("金額")

              Picker("税区分", selection: $row.taxRate) {
                ForEach(TaxRate.allCases, id: \.self) { rate in
                  Text(rate.localizedName).tag(rate)
                }
              }
              .labelsHidden()
              .frame(width: 110)

              HStack(spacing: 4) {
                TextField("取引先 / メモ", text: $row.counterparty)
                Menu {
                  ForEach(counterpartyCandidates, id: \.self) { candidate in
                    Button(candidate) { row.counterparty = candidate }
                  }
                } label: {
                  Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .disabled(counterpartyCandidates.isEmpty)
              }
              .frame(minWidth: 220)

              Button {
                rows.removeAll { $0.id == row.id }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain)
              .disabled(rows.count <= 2)
              .accessibilityLabel("この行を削除")
            }
          }
        }

        HStack {
          Button("行を追加", systemImage: "plus") {
            rows.append(DraftJournalLine(side: rows.last?.side.opposite ?? .debit))
          }
          Button("最後の行を複製", systemImage: "doc.on.doc") {
            guard let last = rows.last else { return }
            rows.append(
              DraftJournalLine(
                accountID: last.accountID,
                side: last.side,
                amountText: last.amountText,
                taxRate: last.taxRate,
                counterparty: last.counterparty,
                memo: last.memo
              ))
          }
          Button("貸借を入替", systemImage: "arrow.left.arrow.right") {
            for index in rows.indices { rows[index].side = rows[index].side.opposite }
          }
          Spacer()
          Text(difference == 0 ? "貸借一致" : "差額 \(difference.formatted())円")
            .font(.headline.monospacedDigit())
            .foregroundStyle(difference == 0 ? .green : .orange)
            .accessibilityLabel(difference == 0 ? "借方と貸方は一致" : "差額 \(difference)円")
        }

        Spacer()

        HStack {
          Text("⌘↩ で記帳")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("確認して記帳") { post() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canPost)
        }
      }
      .padding(32)
    }
  }

  private func amount(of row: DraftJournalLine) -> Int64 {
    Int64(row.amountText.replacingOccurrences(of: ",", with: "")) ?? 0
  }

  private var counterpartyCandidates: [String] {
    Array(
      Set(
        model.journalEntries.flatMap(\.lines).map(\.counterparty).filter { !$0.isEmpty }
      )
    ).sorted()
  }

  private func post() {
    do {
      let lines = try rows.map { row in
        guard let accountID = row.accountID else { throw RepositoryError.notFound }
        return try JournalLine(
          accountID: accountID,
          side: row.side,
          amount: Money(yen: amount(of: row)),
          taxRate: row.taxRate,
          counterparty: row.counterparty,
          memo: row.memo
        )
      }
      model.createAndPostJournal(
        transactionDate: transactionDate,
        description: description,
        lines: lines
      )
      if model.errorMessage == nil {
        description = ""
        rows = [DraftJournalLine(side: .debit), DraftJournalLine(side: .credit)]
      }
    } catch {
      model.errorMessage = "入力行を仕訳へ変換できませんでした。科目と1円以上の金額を確認してください。"
    }
  }
}

struct JournalListView: View {
  @ObservedObject var model: AppModel
  @State private var query = ""
  @State private var selectedID: EntityID?
  @State private var reversingEntry: JournalEntry?
  @State private var correctingEntry: JournalEntry?
  @State private var drilldownAccountID: EntityID?

  private var entries: [JournalEntry] {
    guard !query.isEmpty else { return model.journalEntries }
    return model.journalEntries.filter(matchesQuery)
  }

  var body: some View {
    VStack(spacing: 0) {
      workbenchHeader("仕訳帳", subtitle: "転記済み・取消・訂正を時系列で追跡します。") {
        TextField("日付・金額・取引先・科目・摘要を検索", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(width: 320)
      }
      Divider()
      Table(entries, selection: $selectedID) {
        TableColumn("日付") { Text($0.transactionDate, format: .dateTime.year().month().day()) }
          .width(110)
        TableColumn("摘要", value: \.description)
        TableColumn("借方") { Text(accountSummary($0, side: .debit)) }
        TableColumn("貸方") { Text(accountSummary($0, side: .credit)) }
        TableColumn("金額") { Text(debitTotal($0), format: .number) }
          .width(100)
        TableColumn("状態") { Text($0.status.localizedName) }.width(90)
      }
      .font(.system(size: 14))
      .environment(\.defaultMinListRowHeight, 44)
      Divider()
      HStack {
        Text("転記済み仕訳は物理削除せず、取消・訂正で追跡します。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { reversingEntry = selectedEntry }
          .disabled(selectedEntry?.status != .posted)
        Button("訂正") { correctingEntry = selectedEntry }
          .buttonStyle(.borderedProminent)
          .disabled(selectedEntry?.status != .posted)
        Button("関連元帳") {
          drilldownAccountID = selectedEntry?.lines.first?.accountID
        }
        .disabled(selectedEntry == nil)
      }
      .padding(12)
    }
    .sheet(item: $reversingEntry) { entry in
      JournalReasonSheet(title: "仕訳を取り消す", actionTitle: "反対仕訳を記帳") { reason in
        model.reverseJournal(entry, reason: reason)
        reversingEntry = nil
      }
    }
    .sheet(item: $correctingEntry) { entry in
      JournalCorrectionSheet(model: model, entry: entry) { date, description, lines, reason in
        model.correctJournal(
          entry,
          transactionDate: date,
          description: description,
          lines: lines,
          reason: reason
        )
        correctingEntry = nil
      }
    }
    .sheet(
      isPresented: Binding(
        get: { drilldownAccountID != nil },
        set: { if !$0 { drilldownAccountID = nil } }
      )
    ) {
      if let drilldownAccountID {
        LedgerDrilldownSheet(model: model, accountID: drilldownAccountID)
      }
    }
  }

  private var selectedEntry: JournalEntry? {
    model.journalEntries.first { $0.id == selectedID }
  }

  private func accountSummary(_ entry: JournalEntry, side: PostingSide) -> String {
    entry.lines.filter { $0.side == side }.compactMap { line in
      model.accounts.first { $0.id == line.accountID }?.name
    }.joined(separator: " / ")
  }

  private func debitTotal(_ entry: JournalEntry) -> Int64 {
    (try? entry.totals())?.debits.yen ?? 0
  }

  private func matchesQuery(_ entry: JournalEntry) -> Bool {
    let amount = debitTotal(entry).formatted()
    let date = entry.transactionDate.formatted(date: .numeric, time: .omitted)
    let accountNames = entry.lines.compactMap { line in
      model.accounts.first { $0.id == line.accountID }?.name
    }
    return entry.description.localizedCaseInsensitiveContains(query)
      || amount.localizedCaseInsensitiveContains(query)
      || date.localizedCaseInsensitiveContains(query)
      || accountNames.contains { $0.localizedCaseInsensitiveContains(query) }
      || entry.lines.contains {
        $0.counterparty.localizedCaseInsensitiveContains(query)
          || $0.memo.localizedCaseInsensitiveContains(query)
      }
  }
}

private struct LedgerDrilldownSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  let accountID: EntityID

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.accounts.first { $0.id == accountID }?.name ?? "関連元帳")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("閉じる") { dismiss() }
      }
      .padding(20)
      Divider()
      Table(model.ledger(accountID: accountID)) {
        TableColumn("日付") { Text($0.date, format: .dateTime.month().day()) }
        TableColumn("摘要", value: \.description)
        TableColumn("借方") { Text($0.debit.yen, format: .number) }
        TableColumn("貸方") { Text($0.credit.yen, format: .number) }
        TableColumn("残高") { Text($0.runningBalance.yen, format: .number) }
      }
    }
    .frame(width: 760, height: 480)
  }
}

private struct JournalReasonSheet: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let actionTitle: String
  let action: (String) -> Void
  @State private var reason = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.title2.weight(.semibold))
      Text("元の仕訳は保持し、理由付きの反対仕訳を追加します。")
        .foregroundStyle(.secondary)
      TextField("理由", text: $reason, axis: .vertical)
        .lineLimit(3...5)
      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
        Button(actionTitle) { action(reason) }
          .buttonStyle(.borderedProminent)
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct JournalCorrectionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  let entry: JournalEntry
  let action: (Date, String, [JournalLine], String) -> Void
  @State private var date: Date
  @State private var description: String
  @State private var reason = ""
  @State private var rows: [DraftJournalLine]

  init(
    model: AppModel,
    entry: JournalEntry,
    action: @escaping (Date, String, [JournalLine], String) -> Void
  ) {
    self.model = model
    self.entry = entry
    self.action = action
    _date = State(initialValue: entry.transactionDate)
    _description = State(initialValue: entry.description)
    _rows = State(
      initialValue: entry.lines.map {
        DraftJournalLine(
          accountID: $0.accountID,
          side: $0.side,
          amountText: String($0.amount.yen),
          taxRate: $0.taxRate,
          counterparty: $0.counterparty,
          memo: $0.memo
        )
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("仕訳を訂正").font(.title2.weight(.semibold))
      Text("元仕訳を反対仕訳で取り消し、訂正仕訳を同じ操作で記帳します。")
        .foregroundStyle(.secondary)
      DatePicker("取引日", selection: $date, displayedComponents: .date)
      TextField("摘要", text: $description)
      ForEach($rows) { $row in
        HStack {
          Picker("貸借", selection: $row.side) {
            Text("借方").tag(PostingSide.debit)
            Text("貸方").tag(PostingSide.credit)
          }
          .frame(width: 90)
          Picker("科目", selection: $row.accountID) {
            ForEach(model.accounts.filter(\.isActive)) {
              Text($0.name).tag(Optional($0.id))
            }
          }
          .frame(width: 180)
          TextField("金額", text: $row.amountText)
            .frame(width: 120)
        }
      }
      TextField("訂正理由", text: $reason)
      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
        Button("取消と訂正を記帳") { submit() }
          .buttonStyle(.borderedProminent)
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 620)
  }

  private func submit() {
    do {
      let lines = try rows.map { row in
        guard let accountID = row.accountID, let amount = Int64(row.amountText), amount > 0 else {
          throw JournalError.amountMustBePositive
        }
        return try JournalLine(
          accountID: accountID,
          side: row.side,
          amount: Money(yen: amount),
          taxRate: row.taxRate,
          counterparty: row.counterparty,
          memo: row.memo
        )
      }
      action(date, description, lines, reason)
    } catch {
      model.errorMessage = "訂正行の科目と金額を確認してください。"
    }
  }
}

struct GeneralLedgerView: View {
  @ObservedObject var model: AppModel
  @State private var accountID: EntityID?

  private var items: [LedgerItem] { accountID.map(model.ledger(accountID:)) ?? [] }

  var body: some View {
    VStack(spacing: 0) {
      workbenchHeader("総勘定元帳", subtitle: "仕訳から科目別の増減と残高へドリルダウンします。") {
        Picker("勘定科目", selection: $accountID) {
          Text("科目を選択").tag(EntityID?.none)
          ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
        }
        .frame(width: 240)
      }
      Divider()
      Table(items) {
        TableColumn("日付") { Text($0.date, format: .dateTime.month().day()) }.width(90)
        TableColumn("摘要", value: \.description)
        TableColumn("借方") { Text($0.debit.yen, format: .number) }.width(110)
        TableColumn("貸方") { Text($0.credit.yen, format: .number) }.width(110)
        TableColumn("残高") { Text($0.runningBalance.yen, format: .number) }.width(120)
      }
      .font(.system(size: 14))
      .environment(\.defaultMinListRowHeight, 44)
    }
  }
}

struct TrialBalanceView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      workbenchHeader("残高試算表", subtitle: "借方・貸方の一致を科目別に確認します。") {
        if let trial = model.trialBalance {
          Label(
            trial.isBalanced ? "貸借一致" : "不一致",
            systemImage: trial.isBalanced
              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(trial.isBalanced ? .green : .orange)
        }
      }
      Divider()
      Table(model.trialBalance?.accounts ?? []) {
        TableColumn("コード") { balance in Text(account(balance.accountID)?.code ?? "—") }.width(80)
        TableColumn("勘定科目") { balance in Text(account(balance.accountID)?.name ?? "不明") }
        TableColumn("借方合計") { Text($0.debit.yen, format: .number) }.width(140)
        TableColumn("貸方合計") { Text($0.credit.yen, format: .number) }.width(140)
        TableColumn("差引残高") { Text($0.net.yen, format: .number) }.width(140)
      }
      .font(.system(size: 14))
      .environment(\.defaultMinListRowHeight, 44)
    }
  }

  private func account(_ id: EntityID) -> Account? { model.accounts.first { $0.id == id } }
}

private func workbenchHeader<Accessory: View>(
  _ title: String,
  subtitle: String,
  @ViewBuilder accessory: () -> Accessory
) -> some View {
  HStack(alignment: .center) {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 30, weight: .semibold))
      Text(subtitle).foregroundStyle(.secondary)
    }
    Spacer()
    accessory()
  }
  .padding(32)
}

extension JournalEntryStatus {
  fileprivate var localizedName: String {
    switch self {
    case .draft: "下書き"
    case .pendingReview: "確認待ち"
    case .posted: "転記済み"
    case .reversed: "取消済み"
    case .corrected: "訂正済み"
    }
  }
}
