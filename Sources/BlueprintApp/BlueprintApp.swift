import BlueprintDomain
import SwiftUI

@main
struct BluePrintApplication: App {
  @StateObject private var store = V2WorkspaceStore()

  var body: some Scene {
    WindowGroup {
      Group {
        if store.isLoading {
          ProgressView("データを確認しています")
            .frame(minWidth: 560, minHeight: 420)
        } else if store.isSetupComplete {
          V2RootView(store: store)
        } else {
          V2InitialSetupView(store: store)
        }
      }
      .tint(.indigo)
      .alert(
        "処理を完了できませんでした",
        isPresented: Binding(
          get: { store.errorMessage != nil },
          set: { if !$0 { store.dismissError() } }
        )
      ) {
        Button("閉じる", role: .cancel) { store.dismissError() }
      } message: {
        Text(store.errorMessage ?? "")
      }
    }
    .defaultSize(width: 1_280, height: 860)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新規仕訳") { store.selectedDestination = .daily }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(!store.isSetupComplete)
      }
      CommandMenu("移動") {
        Button("ホーム") { store.selectedDestination = .home }
          .keyboardShortcut("1", modifiers: .command)
        Button("日常処理") { store.selectedDestination = .daily }
          .keyboardShortcut("2", modifiers: .command)
        Button("帳簿") { store.selectedDestination = .books }
          .keyboardShortcut("3", modifiers: .command)
        Button("決算") { store.selectedDestination = .closing }
          .keyboardShortcut("4", modifiers: .command)
        Button("申告") { store.selectedDestination = .filing }
          .keyboardShortcut("5", modifiers: .command)
          .disabled(!store.isFilingSupported)
        Divider()
        Button("データ管理") { store.selectedDestination = .utilities }
          .keyboardShortcut("0", modifiers: [.command, .shift])
      }
    }
  }
}
