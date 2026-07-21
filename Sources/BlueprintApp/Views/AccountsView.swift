import BlueprintDomain
import SwiftUI

struct AccountsView: View {
  @ObservedObject var model: AppModel
  @State private var selectedID: Account.ID?
  @State private var editorAccount: Account?
  @State private var showingDeactivateConfirmation = false

  private var selectedAccount: Account? {
    model.accounts.first { $0.id == selectedID }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          Text("勘定科目")
            .font(.system(size: 30, weight: .semibold))
            .tracking(-0.4)
          Text("使用済みの科目は削除せず、無効化して履歴を保ちます。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        HStack {
          Button {
            let now = Date()
            editorAccount = Account(
              metadata: EntityMetadata(createdAt: now),
              code: "",
              name: "",
              category: .expense,
              normalBalance: .debit,
              defaultTaxRate: .standard10,
              statementSection: .incomeStatementExpense,
              displayOrder: (model.accounts.map(\.displayOrder).max() ?? 0) + 10
            )
          } label: {
            Label("科目を追加", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(.blue)
          .keyboardShortcut("n", modifiers: [.command, .shift])
          Spacer()
        }
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 28)

      Divider()

      Table(model.accounts, selection: $selectedID) {
        TableColumn("コード", value: \.code)
          .width(min: 72, ideal: 88, max: 100)
        TableColumn("勘定科目", value: \.name)
          .width(min: 160, ideal: 220)
        TableColumn("区分") { account in
          Text(account.category.localizedName)
        }
        .width(min: 90, ideal: 110)
        TableColumn("通常残高") { account in
          Text(account.normalBalance == .debit ? "借方" : "貸方")
        }
        .width(88)
        TableColumn("既定税区分") { account in
          Text(account.defaultTaxRate.localizedName)
        }
        .width(min: 100, ideal: 130)
        TableColumn("状態") { account in
          Label(
            account.isActive ? "有効" : "無効",
            systemImage: account.isActive ? "checkmark.circle" : "minus.circle"
          )
          .foregroundStyle(account.isActive ? .primary : .secondary)
        }
        .width(90)
      }
      .font(.system(size: 15))
      .tableStyle(.inset(alternatesRowBackgrounds: false))
      .environment(\.defaultMinListRowHeight, 48)
      .contextMenu(forSelectionType: Account.ID.self) { selection in
        if let id = selection.first, let account = model.accounts.first(where: { $0.id == id }) {
          Button("編集") { editorAccount = account }
          Button("無効化", role: .destructive) {
            selectedID = id
            showingDeactivateConfirmation = true
          }
          .disabled(!account.isActive)
        }
      } primaryAction: { selection in
        if let id = selection.first {
          editorAccount = model.accounts.first { $0.id == id }
        }
      }

      Divider()

      HStack {
        Text("\(model.accounts.filter(\.isActive).count)件の有効な科目")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("編集") {
          editorAccount = selectedAccount
        }
        .disabled(selectedAccount == nil)
        Button("無効化") {
          showingDeactivateConfirmation = true
        }
        .disabled(selectedAccount?.isActive != true)
      }
      .padding(12)
      .padding(.horizontal, 12)
    }
    .sheet(item: $editorAccount) { account in
      AccountEditorView(account: account) { updated in
        model.saveAccount(updated)
        editorAccount = nil
      }
    }
    .confirmationDialog(
      "この勘定科目を無効化しますか？",
      isPresented: $showingDeactivateConfirmation
    ) {
      Button("無効化", role: .destructive) {
        if let selectedAccount { model.deactivateAccount(selectedAccount) }
      }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text("過去の記録は保持され、新しい入力候補から外れます。")
    }
  }
}

private struct AccountEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State var account: Account
  let onSave: (Account) -> Void

  private var canSave: Bool {
    !account.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(account.isSystem ? "勘定科目を編集" : "勘定科目")
        .font(.title2.weight(.semibold))

      Form {
        TextField("コード", text: $account.code)
        TextField("名称", text: $account.name)
        Picker("区分", selection: $account.category) {
          ForEach(AccountCategory.allCases, id: \.self) { category in
            Text(category.localizedName).tag(category)
          }
        }
        Picker("通常残高", selection: $account.normalBalance) {
          Text("借方").tag(BalanceDirection.debit)
          Text("貸方").tag(BalanceDirection.credit)
        }
        Picker("既定税区分", selection: $account.defaultTaxRate) {
          ForEach(TaxRate.allCases, id: \.self) { rate in
            Text(rate.localizedName).tag(rate)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") { onSave(account) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}
