import BlueprintBilling
import BlueprintClosing
import BlueprintDocuments
import SwiftUI

struct HomeDashboardView: View {
  @ObservedObject var model: AppModel

  private var pendingReviewCount: Int {
    model.evidenceDocuments.filter { $0.state == .needsReview }.count
      + model.importedTransactions.filter { $0.state == .needsReview }.count
  }

  private var overdueReceivableCount: Int {
    model.invoices.filter { $0.status == .overdue }.count
  }

  private var overduePayableCount: Int {
    let now = Date()
    return model.vendorBills.filter {
      $0.dueDate < now && $0.status != .paid && $0.status != .cancelled
    }.count
  }

  private var closingBlockerCount: Int {
    model.closingChecklist.items.filter {
      !$0.isResolved && $0.severity == .blocking
    }.count
  }

  private var filingBlockerCount: Int {
    if !model.isFilingSupported { return 1 }
    return model.unsupportedFilingCases.count
  }

  private var nextAction: (title: String, detail: String, destination: AppDestination) {
    if pendingReviewCount > 0 {
      return (
        "未確認の証憑・取引を確認",
        "\(pendingReviewCount)件の候補を確認してから仕訳へ進みます。",
        .daily
      )
    }
    if overdueReceivableCount + overduePayableCount > 0 {
      return (
        "期限超過を確認",
        "未収\(overdueReceivableCount)件、未払\(overduePayableCount)件があります。",
        .daily
      )
    }
    if closingBlockerCount > 0 {
      return (
        "決算ブロッカーを解消",
        "\(closingBlockerCount)件の必須確認が残っています。",
        .closing
      )
    }
    if model.isFilingSupported {
      return ("申告内容を確認", "集計値と根拠資料を確認します。", .filing)
    }
    return ("日常処理を続ける", "申告出力の確定までは帳簿を継続できます。", .daily)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 5) {
          Text("作業状況")
            .font(.largeTitle.weight(.semibold))
          Text("未処理とブロッカーを、次に行う作業の順で表示します。")
            .foregroundStyle(.secondary)
        }

        Button {
          model.session.selectedDestination = nextAction.destination
        } label: {
          HStack(spacing: 16) {
            Image(systemName: "arrow.right.circle.fill")
              .font(.system(size: 32))
              .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
              Text("次に行うこと")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(nextAction.title)
                .font(.title3.weight(.semibold))
              Text(nextAction.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .foregroundStyle(.secondary)
          }
          .padding(20)
          .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("該当するワークスペースを開きます")

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14),
          ],
          spacing: 14
        ) {
          WorkspaceStatusCard(
            title: "未確認",
            value: pendingReviewCount,
            detail: "証憑・取引候補",
            icon: "tray.full",
            tint: .indigo
          ) {
            model.session.selectedDestination = .daily
          }
          WorkspaceStatusCard(
            title: "期限超過",
            value: overdueReceivableCount + overduePayableCount,
            detail: "未収・未払",
            icon: "calendar.badge.exclamationmark",
            tint: .orange
          ) {
            model.session.selectedDestination = .daily
          }
          WorkspaceStatusCard(
            title: "決算ブロッカー",
            value: closingBlockerCount,
            detail: "必須確認",
            icon: "checklist",
            tint: .red
          ) {
            model.session.selectedDestination = .closing
          }
          WorkspaceStatusCard(
            title: "申告ブロッカー",
            value: filingBlockerCount,
            detail: model.isFilingSupported ? "未対応ケース" : "年度ルール待ち",
            icon: "doc.text.magnifyingglass",
            tint: .purple
          ) {
            if model.isFilingSupported { model.session.selectedDestination = .filing }
          }
          WorkspaceStatusCard(
            title: "仕訳",
            value: model.journalEntries.count,
            detail: "当年度の記録",
            icon: "book.closed",
            tint: .blue
          ) {
            model.session.selectedDestination = .books
          }
          WorkspaceStatusCard(
            title: "証憑",
            value: model.evidenceDocuments.count,
            detail: "原本保存済み",
            icon: "doc.viewfinder",
            tint: .green
          ) {
            model.session.selectedDestination = .daily
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 1_060, alignment: .leading)
    }
  }
}

private struct WorkspaceStatusCard: View {
  let title: String
  let value: Int
  let detail: String
  let icon: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: icon)
            .foregroundStyle(tint)
          Spacer()
          Text(value.formatted())
            .font(.title.weight(.semibold))
            .monospacedDigit()
        }
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.quaternary, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }
}

struct DailyWorkspaceView: View {
  enum Section: String, CaseIterable, Identifiable {
    case inbox = "受信箱"
    case entry = "取引入力"
    case billing = "請求・支払"
    var id: String { rawValue }
  }

  @ObservedObject var model: AppModel
  @State private var section = Section.inbox

  var body: some View {
    VStack(spacing: 0) {
      Picker("日常処理", selection: $section) {
        ForEach(Section.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 24)
      .padding(.vertical, 12)

      Divider()

      switch section {
      case .inbox:
        EvidenceInboxView(model: model)
      case .entry:
        JournalEntryView(model: model)
      case .billing:
        BillingWorkbenchView(model: model)
      }
    }
  }
}

struct BooksWorkspaceView: View {
  enum Section: String, CaseIterable, Identifiable {
    case journal = "仕訳帳"
    case ledger = "総勘定元帳"
    case trialBalance = "試算表"
    case accounts = "勘定科目"
    var id: String { rawValue }
  }

  @ObservedObject var model: AppModel
  @State private var section = Section.journal

  var body: some View {
    VStack(spacing: 0) {
      Picker("帳簿", selection: $section) {
        ForEach(Section.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 24)
      .padding(.vertical, 12)

      Divider()

      switch section {
      case .journal:
        JournalListView(model: model)
      case .ledger:
        GeneralLedgerView(model: model)
      case .trialBalance:
        TrialBalanceView(model: model)
      case .accounts:
        AccountsView(model: model)
      }
    }
  }
}
