import BlueprintDomain
import SwiftUI

struct BusinessSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var draft: BusinessProfile?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          Text("事業者・税務設定")
            .font(.title2.weight(.semibold))
          Text("変更内容は年度データと監査記録へ保存されます。")
            .foregroundStyle(.secondary)
        }

        if let draftBinding = Binding($draft) {
          Form {
            Section("事業者") {
              TextField("氏名", text: draftBinding.ownerName)
              TextField("屋号", text: draftBinding.tradeName)
              TextField("住所", text: draftBinding.postalAddress)
              TextField("納税地", text: draftBinding.taxAddress)
              TextField("所轄税務署", text: draftBinding.taxOffice)
              TextField("業種", text: draftBinding.industry)
            }
            Section("税務") {
              Toggle("青色申告承認済み", isOn: draftBinding.blueReturnApproved)
              Picker("消費税区分", selection: draftBinding.consumptionTaxStatus) {
                Text("免税事業者").tag(ConsumptionTaxStatus.exempt)
                Text("課税・一般").tag(ConsumptionTaxStatus.generalTaxation)
                Text("課税・簡易").tag(ConsumptionTaxStatus.simplifiedTaxation)
                Text("年度別特例").tag(ConsumptionTaxStatus.annualSpecialRule)
              }
              Picker("インボイス", selection: draftBinding.invoiceRegistrationStatus) {
                Text("登録済み").tag(InvoiceRegistrationStatus.qualified)
                Text("免税・未登録").tag(InvoiceRegistrationStatus.exemptOrUnregistered)
                Text("未確認").tag(InvoiceRegistrationStatus.unknown)
              }
              TextField(
                "登録番号",
                text: Binding(
                  get: { draft?.invoiceRegistrationNumber ?? "" },
                  set: { draft?.invoiceRegistrationNumber = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("T1234567890123")
              )
              Picker("経理方式", selection: draftBinding.taxAccountingMethod) {
                Text("税込経理").tag(TaxAccountingMethod.taxInclusive)
                Text("税抜経理").tag(TaxAccountingMethod.taxExclusive)
              }
              Picker("端数処理", selection: draftBinding.roundingRule) {
                Text("切り捨て").tag(RoundingRule.down)
                Text("切り上げ").tag(RoundingRule.up)
                Text("四捨五入").tag(RoundingRule.nearest)
              }
            }
          }
          .formStyle(.grouped)

          HStack {
            Label("税務設定の年度影響表示は v0.7 で拡張します", systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            Button("変更を保存") {
              if let draft { model.updateProfile(draft) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 820)
    }
    .onAppear { draft = model.profile }
    .onChange(of: model.profile) { _, newValue in draft = newValue }
  }
}
