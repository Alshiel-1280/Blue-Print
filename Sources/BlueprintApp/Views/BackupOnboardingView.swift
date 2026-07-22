import SwiftUI

struct BackupOnboardingView: View {
  let configure: () -> Void
  let postpone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "externaldrive.badge.timemachine")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(.indigo)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text("最初にバックアップを設定してください")
            .font(.title2.weight(.semibold))
          Text("このMacが会計データの正本です。故障や誤操作に備え、暗号化バックアップを別の保存先へ作成してください。")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        Label("12文字以上のパスフレーズでAES-256-GCM暗号化", systemImage: "lock.shield")
        Label("日次・7世代の自動バックアップ", systemImage: "clock.arrow.circlepath")
        Label("復元前に件数・残高・証憑ハッシュを確認", systemImage: "checkmark.seal")
      }
      .font(.subheadline)

      Text("パスフレーズを失うと復元できません。会計データとは別の安全な場所で管理してください。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

      HStack {
        Button("あとで設定", action: postpone)
        Spacer()
        Button("バックアップを設定", systemImage: "arrow.right", action: configure)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(28)
    .frame(width: 560)
    .accessibilityElement(children: .contain)
  }
}
