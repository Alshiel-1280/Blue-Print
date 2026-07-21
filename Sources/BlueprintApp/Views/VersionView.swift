import BlueprintDomain
import SwiftUI

struct VersionView: View {
  private let rows: [(String, String)] = [
    ("アプリ", BlueprintVersions.app),
    ("DBスキーマ", String(BlueprintVersions.databaseSchema)),
    ("データ形式", String(BlueprintVersions.dataFormat)),
    ("年度ルール", BlueprintVersions.taxRuleSet),
    ("帳票ルール", BlueprintVersions.formRuleSet),
    ("撮影プロトコル", String(BlueprintVersions.captureProtocol)),
    ("ビルド", BlueprintVersions.buildOrigin),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("バージョン情報")
          .font(.title2.weight(.semibold))
        Text("問い合わせやデータ移行時は、以下の値を確認してください。")
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 0) {
        ForEach(rows, id: \.0) { row in
          GridRow {
            Text(row.0)
              .foregroundStyle(.secondary)
              .frame(width: 140, alignment: .leading)
            Text(row.1)
              .textSelection(.enabled)
            Spacer()
          }
          .padding(.vertical, 10)
          Divider()
            .gridCellColumns(3)
        }
      }
      .padding(.top, 8)

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
