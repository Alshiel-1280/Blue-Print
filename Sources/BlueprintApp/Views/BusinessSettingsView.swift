import BlueprintDomain
import BlueprintTax
import SwiftUI

struct BusinessSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var draft: BusinessProfile?
  @State private var calendarYear = OfficialRulePackages.latestSupportedYear
  @State private var showingLockConfirmation = false
  @State private var reopenReason = ""

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
            Section("年度制御") {
              LabeledContent("状態", value: model.fiscalYear?.status.localizedName ?? "未設定")
              Picker("申告年度", selection: $calendarYear) {
                if let currentYear = model.fiscalYear?.calendarYear,
                  !OfficialRulePackages.supportedYears.contains(currentYear)
                {
                  Text("\(currentYear)年（e-Tax未対応）").tag(currentYear)
                }
                ForEach(OfficialRulePackages.supportedYears, id: \.self) { year in
                  let filingSupported =
                    OfficialRulePackages.store.support(for: year)?.supports(.xtx) == true
                  Text("\(year)年\(filingSupported ? "" : "（申告出力未対応）")").tag(year)
                }
              }
              if let support = OfficialRulePackages.store.support(for: calendarYear) {
                LabeledContent("年度ルール") {
                  Text(
                    support.supportedScopes
                      .sorted { $0.rawValue < $1.rawValue }
                      .map(\.localizedName)
                      .joined(separator: "・")
                  )
                  .multilineTextAlignment(.trailing)
                }
                Text("ルール版 \(support.packageRevision) は署名と内容ハッシュを検証済みです。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if calendarYear != model.fiscalYear?.calendarYear {
                Button("申告年度を\(calendarYear)年へ修正") {
                  model.changeFiscalYear(to: calendarYear)
                }
                .disabled(!model.canChangeFiscalYear)
              }
              if model.canChangeFiscalYear {
                Text("年度データがまだないため、申告年度と税務・e-Taxルールを安全に修正できます。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Text("仕訳、証憑、請求、申告資料などがある年度は変更できません。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if model.fiscalYear?.status == .locked {
                TextField("再オープン理由", text: $reopenReason)
                Button("理由を記録して再オープン") {
                  model.reopenFiscalYear(reason: reopenReason)
                  if model.errorMessage == nil { reopenReason = "" }
                }
                .disabled(reopenReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              } else {
                Button("年度をロック", role: .destructive) {
                  showingLockConfirmation = true
                }
              }
            }
            Section("事業者") {
              TextField("氏名", text: draftBinding.ownerName)
              TextField("屋号", text: draftBinding.tradeName)
              TextField("住所", text: draftBinding.postalAddress)
              TextField("納税地", text: draftBinding.taxAddress)
              TextField("所轄税務署", text: draftBinding.taxOffice)
              TextField("税務署番号（5桁）", text: draftBinding.taxOfficeCode)
              TextField("e-Tax利用者識別番号（16桁）", text: draftBinding.eTaxUserID)
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
    .onAppear {
      draft = model.profile
      calendarYear = model.fiscalYear?.calendarYear ?? OfficialRulePackages.latestSupportedYear
    }
    .onChange(of: model.profile) { _, newValue in draft = newValue }
    .onChange(of: model.fiscalYear) { _, newValue in
      calendarYear = newValue?.calendarYear ?? OfficialRulePackages.latestSupportedYear
    }
    .confirmationDialog(
      "年度をロックしますか？",
      isPresented: $showingLockConfirmation
    ) {
      Button("年度をロック", role: .destructive) { model.lockFiscalYear() }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text("ロック後は仕訳、インポート、年度設定の変更を拒否します。再オープンには理由が必要です。")
    }
  }
}

extension RuleScope {
  fileprivate var localizedName: String {
    switch self {
    case .bookkeeping: "記帳"
    case .consumptionTax: "消費税"
    case .closing: "決算"
    case .incomeTaxForm: "所得税帳票"
    case .xtx: "XTX"
    }
  }
}

extension FiscalYearStatus {
  fileprivate var localizedName: String {
    switch self {
    case .open: "入力受付中"
    case .closing: "決算整理中"
    case .filed: "申告済み"
    case .locked: "ロック済み"
    }
  }
}
