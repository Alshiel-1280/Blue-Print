import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
  case home
  case daily
  case books
  case inbox
  case transactionInput
  case billing
  case closing
  case filing
  case journal
  case ledger
  case trialBalance
  case accounts
  case businessSettings
  case dataManagement
  case versions
  case audit

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: "ホーム"
    case .daily: "日常処理"
    case .books: "帳簿"
    case .inbox: "受信箱"
    case .transactionInput: "取引入力"
    case .billing: "請求・支払"
    case .closing: "決算・レポート"
    case .filing: "申告ワークスペース"
    case .journal: "仕訳帳"
    case .ledger: "総勘定元帳"
    case .trialBalance: "試算表"
    case .accounts: "勘定科目"
    case .businessSettings: "事業者設定"
    case .dataManagement: "データ管理"
    case .versions: "バージョン"
    case .audit: "監査記録"
    }
  }

  var icon: String {
    switch self {
    case .home: "house"
    case .daily: "tray.and.arrow.down"
    case .books: "books.vertical"
    case .inbox: "tray.full"
    case .transactionInput: "square.and.pencil"
    case .billing: "doc.text"
    case .closing: "checklist"
    case .filing: "doc.text.magnifyingglass"
    case .journal: "book.closed"
    case .ledger: "books.vertical"
    case .trialBalance: "tablecells"
    case .accounts: "cylinder.split.1x2"
    case .businessSettings: "gearshape"
    case .dataManagement: "externaldrive.badge.timemachine"
    case .versions: "info.circle"
    case .audit: "clock.arrow.trianglehead.counterclockwise.rotate.90"
    }
  }
}

struct MainShellView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var session: AppSessionStore
  @AppStorage("didShowBackupOnboarding") private var didShowBackupOnboarding = false
  @State private var isBackupOnboardingPresented = false

  init(model: AppModel) {
    self.model = model
    session = model.session
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.profile?.tradeName ?? "Blue-Print")
            .font(.headline)
            .lineLimit(1)
          Text(model.fiscalYear.map { "\($0.calendarYear)年" } ?? "年度未設定")
            .font(.caption)
            .foregroundStyle(.secondary)
          if model.fiscalYear != nil && !model.isFilingSupported {
            Label("申告出力は未対応", systemImage: "exclamationmark.triangle")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        List(selection: $session.selectedDestination) {
          Section("ワークスペース") {
            NavigationLink(value: AppDestination.home) {
              Label(AppDestination.home.title, systemImage: AppDestination.home.icon)
            }
            NavigationLink(value: AppDestination.daily) {
              HStack {
                Label(AppDestination.daily.title, systemImage: AppDestination.daily.icon)
                Spacer()
                let pending =
                  model.evidenceDocuments.filter { $0.state == .needsReview }.count
                  + model.importedTransactions.filter { $0.state == .needsReview }.count
                if pending > 0 {
                  Text("\(pending)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.indigo.opacity(0.12), in: Capsule())
                }
              }
            }
            NavigationLink(value: AppDestination.books) {
              Label(AppDestination.books.title, systemImage: AppDestination.books.icon)
            }
            NavigationLink(value: AppDestination.closing) {
              Label(AppDestination.closing.title, systemImage: AppDestination.closing.icon)
            }
            NavigationLink(value: AppDestination.filing) {
              Label(AppDestination.filing.title, systemImage: AppDestination.filing.icon)
            }
            .disabled(!model.isFilingSupported)
          }
          Section("ユーティリティ") {
            NavigationLink(value: AppDestination.businessSettings) {
              Label(
                AppDestination.businessSettings.title,
                systemImage: AppDestination.businessSettings.icon)
            }
            NavigationLink(value: AppDestination.dataManagement) {
              Label(
                AppDestination.dataManagement.title, systemImage: AppDestination.dataManagement.icon
              )
            }
            NavigationLink(value: AppDestination.audit) {
              Label(AppDestination.audit.title, systemImage: AppDestination.audit.icon)
            }
            NavigationLink(value: AppDestination.versions) {
              Label(AppDestination.versions.title, systemImage: AppDestination.versions.icon)
            }
          }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("メインナビゲーション")

        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 2) {
            Text("ローカルに保存済み")
              .font(.caption)
            Text("Macが正本です")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(14)
        .accessibilityElement(children: .combine)
      }
      .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
    } detail: {
      switch session.selectedDestination ?? .home {
      case .home:
        HomeDashboardView(model: model)
      case .daily:
        DailyWorkspaceView(model: model)
      case .books:
        BooksWorkspaceView(model: model)
      case .inbox:
        EvidenceInboxView(model: model)
      case .transactionInput:
        JournalEntryView(model: model)
      case .billing:
        BillingWorkbenchView(model: model)
      case .closing:
        ClosingWorkbenchView(model: model)
      case .filing:
        FilingWorkspaceView(model: model)
      case .journal:
        JournalListView(model: model)
      case .ledger:
        GeneralLedgerView(model: model)
      case .trialBalance:
        TrialBalanceView(model: model)
      case .accounts:
        AccountsView(model: model)
      case .businessSettings:
        BusinessSettingsView(model: model)
      case .dataManagement:
        DataManagementView(model: model)
      case .versions:
        VersionView()
      case .audit:
        AuditView(model: model)
      }
    }
    .navigationTitle(session.selectedDestination?.title ?? "Blue-Print")
    .frame(minWidth: 1_040, minHeight: 700)
    .task {
      if !didShowBackupOnboarding { isBackupOnboardingPresented = true }
    }
    .sheet(isPresented: $isBackupOnboardingPresented) {
      BackupOnboardingView {
        didShowBackupOnboarding = true
        isBackupOnboardingPresented = false
        model.session.selectedDestination = .dataManagement
      } postpone: {
        didShowBackupOnboarding = true
        isBackupOnboardingPresented = false
      }
    }
  }
}
