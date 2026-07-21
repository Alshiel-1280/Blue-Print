import BlueprintDomain
import SwiftUI

@main
struct BluePrintApplication: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if model.isLoading {
          ProgressView("データを確認しています")
            .frame(minWidth: 560, minHeight: 420)
        } else if model.isSetupComplete {
          MainShellView(model: model)
        } else {
          InitialSetupView(model: model)
        }
      }
      .tint(.indigo)
      .alert(
        "処理を完了できませんでした",
        isPresented: Binding(
          get: { model.errorMessage != nil },
          set: { if !$0 { model.dismissError() } }
        )
      ) {
        Button("閉じる", role: .cancel) { model.dismissError() }
      } message: {
        Text(model.presentedErrorMessage ?? "")
      }
    }
    .defaultSize(width: 1_280, height: 860)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新規作成") {}
          .keyboardShortcut("n", modifiers: .command)
          .disabled(true)
      }
      CommandMenu("移動") {
        Button("受信箱") { model.selectedDestination = .inbox }
          .keyboardShortcut("1", modifiers: .command)
        Button("取引入力") { model.selectedDestination = .transactionInput }
          .keyboardShortcut("2", modifiers: .command)
        Button("請求・支払") { model.selectedDestination = .billing }
          .keyboardShortcut("3", modifiers: .command)
        Button("決算・レポート") { model.selectedDestination = .closing }
          .keyboardShortcut("4", modifiers: .command)
        Button("申告ワークスペース") { model.selectedDestination = .filing }
          .keyboardShortcut("5", modifiers: .command)
        Divider()
        Button("データ管理") { model.selectedDestination = .dataManagement }
          .keyboardShortcut("0", modifiers: [.command, .shift])
      }
    }
  }
}
