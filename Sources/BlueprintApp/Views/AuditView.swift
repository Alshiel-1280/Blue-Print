import BlueprintAudit
import SwiftUI

struct AuditView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("監査記録")
            .font(.title2.weight(.semibold))
          Text("この一覧は追記専用です。通常操作から変更・削除できません。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      Divider()

      Table(model.auditEvents) {
        TableColumn("日時") { event in
          Text(event.occurredAt, format: .dateTime.year().month().day().hour().minute())
        }
        .width(min: 150, ideal: 180)
        TableColumn("操作") { event in
          Text(event.action.localizedName)
        }
        .width(130)
        TableColumn("対象") { event in
          Text(event.targetType)
        }
        .width(130)
        TableColumn("対象ID") { event in
          Text(event.targetID)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
        }
        TableColumn("理由") { event in
          Text(event.reason ?? "—")
        }
      }
    }
  }
}
