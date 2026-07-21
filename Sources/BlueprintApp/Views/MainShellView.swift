import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
  case accounts
  case businessSettings
  case versions
  case audit

  var id: String { rawValue }

  var title: String {
    switch self {
    case .accounts: "勘定科目"
    case .businessSettings: "事業者設定"
    case .versions: "バージョン"
    case .audit: "監査記録"
    }
  }

  var icon: String {
    switch self {
    case .accounts: "cylinder.split.1x2"
    case .businessSettings: "gearshape"
    case .versions: "info.circle"
    case .audit: "clock.arrow.trianglehead.counterclockwise.rotate.90"
    }
  }
}

struct MainShellView: View {
  @ObservedObject var model: AppModel
  @State private var destination: AppDestination? = .accounts

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        List(selection: $destination) {
          Section("マスター") {
            NavigationLink(value: AppDestination.accounts) {
              Label(AppDestination.accounts.title, systemImage: AppDestination.accounts.icon)
            }
          }
          Section("設定") {
            NavigationLink(value: AppDestination.businessSettings) {
              Label(
                AppDestination.businessSettings.title,
                systemImage: AppDestination.businessSettings.icon)
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
      switch destination ?? .accounts {
      case .accounts:
        AccountsView(model: model)
      case .businessSettings:
        BusinessSettingsView(model: model)
      case .versions:
        VersionView()
      case .audit:
        AuditView(model: model)
      }
    }
    .navigationTitle(destination?.title ?? "Blue-Print")
    .frame(minWidth: 1_040, minHeight: 700)
  }
}
