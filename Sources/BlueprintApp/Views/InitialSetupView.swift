import BlueprintDomain
import BlueprintTax
import SwiftUI

struct InitialSetupView: View {
  @ObservedObject var model: AppModel

  @State private var ownerName = ""
  @State private var tradeName = ""
  @State private var calendarYear = Calendar.current.component(.year, from: Date())
  @State private var consumptionTaxStatus = ConsumptionTaxStatus.exempt
  @State private var invoiceStatus = InvoiceRegistrationStatus.unknown
  @State private var bookkeepingStyle = BookkeepingStyle.doubleEntry
  @State private var taxAccountingMethod = TaxAccountingMethod.taxInclusive
  @State private var roundingRule = RoundingRule.down

  private var canContinue: Bool {
    !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !tradeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasFilingRules: Bool {
    (try? OfficialRules2025.catalog.rules(for: calendarYear)) != nil
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 24) {
        Label("Blue-Print", systemImage: "book.closed")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.indigo)

        Spacer()

        Text("Macに、あなたの帳簿を\nつくります。")
          .font(.system(size: 34, weight: .semibold))
          .tracking(-0.6)

        Text("会計データはこのMacを正本として保存します。まず事業者と申告年度を設定してください。")
          .font(.body)
          .foregroundStyle(.secondary)
          .lineSpacing(4)
          .frame(maxWidth: 320, alignment: .leading)

        Spacer()

        Label("外部サービスへの送信なし", systemImage: "lock.shield")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityLabel("通常の記帳データは外部サービスへ送信しません")
      }
      .padding(44)
      .frame(width: 420, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .leading)
      .background(Color(nsColor: .windowBackgroundColor))

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          VStack(alignment: .leading, spacing: 6) {
            Text("初回セットアップ")
              .font(.title2.weight(.semibold))
            Text("あとから事業者設定で変更できます。過年度への影響がある変更は今後明示します。")
              .foregroundStyle(.secondary)
          }

          Form {
            Section("事業者") {
              TextField("氏名", text: $ownerName, prompt: Text("青空 太郎"))
                .textContentType(.name)
                .accessibilityHint("申告する本人の氏名を入力します")
              TextField("屋号", text: $tradeName, prompt: Text("青空デザイン"))
                .accessibilityHint("屋号がない場合は氏名を入力します")
              Stepper("申告年度: \(calendarYear)年", value: $calendarYear, in: 2000...2100)
              if !hasFilingRules {
                Label(
                  "この年度の申告・e-Taxルールは未登録です。帳簿は作成できますが、申告出力はルール追加後に利用できます。",
                  systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
              }
            }

            Section("申告と記帳") {
              Picker("記帳方式", selection: $bookkeepingStyle) {
                Text("複式簿記").tag(BookkeepingStyle.doubleEntry)
                Text("簡易簿記").tag(BookkeepingStyle.simple)
              }
              Picker("消費税区分", selection: $consumptionTaxStatus) {
                Text("免税事業者").tag(ConsumptionTaxStatus.exempt)
                Text("課税・一般").tag(ConsumptionTaxStatus.generalTaxation)
                Text("課税・簡易").tag(ConsumptionTaxStatus.simplifiedTaxation)
                Text("年度別特例").tag(ConsumptionTaxStatus.annualSpecialRule)
              }
              Picker("インボイス", selection: $invoiceStatus) {
                Text("登録済み").tag(InvoiceRegistrationStatus.qualified)
                Text("免税・未登録").tag(InvoiceRegistrationStatus.exemptOrUnregistered)
                Text("未確認").tag(InvoiceRegistrationStatus.unknown)
              }
              Picker("経理方式", selection: $taxAccountingMethod) {
                Text("税込経理").tag(TaxAccountingMethod.taxInclusive)
                Text("税抜経理").tag(TaxAccountingMethod.taxExclusive)
              }
              Picker("端数処理", selection: $roundingRule) {
                Text("切り捨て").tag(RoundingRule.down)
                Text("切り上げ").tag(RoundingRule.up)
                Text("四捨五入").tag(RoundingRule.nearest)
              }
            }
          }
          .formStyle(.grouped)

          HStack {
            Label("標準勘定科目を重複なく作成します", systemImage: "checkmark.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            Button("帳簿を作成") {
              model.createInitialSetup(
                ownerName: ownerName,
                tradeName: tradeName,
                calendarYear: calendarYear,
                consumptionTaxStatus: consumptionTaxStatus,
                invoiceStatus: invoiceStatus,
                bookkeepingStyle: bookkeepingStyle,
                taxAccountingMethod: taxAccountingMethod,
                roundingRule: roundingRule
              )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
            .accessibilityHint("事業者、年度、標準勘定科目をこのMacに保存します")
          }
        }
        .padding(40)
        .frame(maxWidth: 760)
      }
      .background(Color(nsColor: .controlBackgroundColor))
    }
    .frame(minWidth: 980, minHeight: 680)
  }
}
