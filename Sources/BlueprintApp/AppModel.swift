import BlueprintAudit
import BlueprintDomain
import BlueprintPersistence
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var profile: BusinessProfile?
  @Published private(set) var fiscalYear: FiscalYear?
  @Published private(set) var accounts: [Account] = []
  @Published private(set) var auditEvents: [AuditEvent] = []
  @Published private(set) var isLoading = true
  @Published var errorMessage: String?

  private var database: BlueprintDatabase?
  private let clock: any BlueprintClock

  init(database: BlueprintDatabase? = nil, clock: any BlueprintClock = SystemClock()) {
    self.clock = clock
    do {
      self.database = try database ?? Self.makeDefaultDatabase()
      try reload()
    } catch {
      self.database = nil
      errorMessage = Self.userFacingMessage(for: error)
    }
    isLoading = false
  }

  var isSetupComplete: Bool { profile != nil && fiscalYear != nil }

  func createInitialSetup(
    ownerName: String,
    tradeName: String,
    calendarYear: Int,
    consumptionTaxStatus: ConsumptionTaxStatus,
    invoiceStatus: InvoiceRegistrationStatus,
    bookkeepingStyle: BookkeepingStyle,
    taxAccountingMethod: TaxAccountingMethod,
    roundingRule: RoundingRule
  ) {
    guard let database else {
      errorMessage = "データベースを開けないため保存できません。アプリを再起動し、改善しない場合は保存先の権限を確認してください。"
      return
    }
    let normalizedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTradeName = tradeName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedOwner.isEmpty else {
      errorMessage = "氏名が未入力です。申告する本人の氏名を入力してください。"
      return
    }
    guard !normalizedTradeName.isEmpty else {
      errorMessage = "屋号が未入力です。屋号がない場合は、氏名と同じ内容を入力してください。"
      return
    }

    do {
      let now = clock.now()
      let fiscalYear = try FiscalYear(
        metadata: EntityMetadata(createdAt: now),
        calendarYear: calendarYear,
        taxRuleSetID: BlueprintVersions.taxRuleSet,
        formRuleSetID: BlueprintVersions.formRuleSet
      )
      let profile = BusinessProfile(
        metadata: EntityMetadata(createdAt: now),
        fiscalYearID: fiscalYear.id,
        ownerName: normalizedOwner,
        tradeName: normalizedTradeName,
        bookkeepingStyle: bookkeepingStyle,
        consumptionTaxStatus: consumptionTaxStatus,
        invoiceRegistrationStatus: invoiceStatus,
        taxAccountingMethod: taxAccountingMethod,
        roundingRule: roundingRule
      )
      try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func updateProfile(_ updated: BusinessProfile) {
    guard let database else { return }
    do {
      var profile = updated
      profile.metadata.touch(at: clock.now())
      try database.saveProfile(profile, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func saveAccount(_ account: Account) {
    guard let database else { return }
    do {
      var account = account
      account.metadata.touch(at: clock.now())
      try database.saveAccount(account, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func deactivateAccount(_ account: Account) {
    guard let database else { return }
    do {
      try database.deactivateAccount(id: account.id, at: clock.now())
      errorMessage = nil
      try reload()
    } catch {
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  func dismissError() {
    errorMessage = nil
  }

  private func reload() throws {
    guard let database else { return }
    profile = try database.profiles.fetchAll().first
    fiscalYear = try database.fiscalYears.fetchAll().first
    accounts = try database.accounts.fetchAll(includeInactive: true)
    auditEvents = try database.auditEvents.fetchAll()
  }

  private static func userFacingMessage(for error: Error) -> String {
    switch error {
    case RepositoryError.physicalDeletionForbidden:
      "使用履歴を守るため勘定科目は削除できません。代わりに無効化してください。"
    case RepositoryError.duplicate:
      "同じデータが既にあります。内容を確認して重複を解消してください。"
    case FiscalYearError.unsupportedCalendarYear:
      "対応範囲外の年度です。2000年から2100年の範囲で入力してください。"
    default:
      "保存処理を完了できませんでした。入力内容と保存先の空き容量を確認し、もう一度実行してください。"
    }
  }

  private static func makeDefaultDatabase() throws -> BlueprintDatabase {
    #if DEBUG
      if let root = ProcessInfo.processInfo.environment["BLUEPRINT_DATA_ROOT"], !root.isEmpty {
        let layout = StorageLayout(root: URL(fileURLWithPath: root, isDirectory: true))
        try layout.createDirectories()
        return try BlueprintDatabase(
          databaseURL: layout.databaseURL,
          backupHook: FileMigrationBackupHook(backupDirectory: layout.automaticBackupDirectory)
        )
      }
    #endif
    return try BlueprintDatabase.openDefault()
  }
}
