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
        Text(model.errorMessage ?? "")
      }
    }
    .defaultSize(width: 1_280, height: 860)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新規作成") {}
          .keyboardShortcut("n", modifiers: .command)
          .disabled(true)
      }
    }
  }
}
