import BlueprintAudit
import BlueprintDomain
import Foundation

public final class BlueprintDatabase: @unchecked Sendable {
  public let connection: SQLiteConnection
  public let profiles: SQLiteBusinessProfileRepository
  public let fiscalYears: SQLiteFiscalYearRepository
  public let accounts: SQLiteAccountRepository
  public let auditEvents: SQLiteAuditEventRepository

  public init(
    databaseURL: URL,
    backupHook: any MigrationBackupHook = NoopMigrationBackupHook()
  ) throws {
    let connection = try SQLiteConnection(databaseURL: databaseURL)
    try DatabaseMigrator().migrate(connection: connection, backupHook: backupHook)
    try connection.enableWriteAheadLogging()
    self.connection = connection
    profiles = SQLiteBusinessProfileRepository(connection: connection)
    fiscalYears = SQLiteFiscalYearRepository(connection: connection)
    accounts = SQLiteAccountRepository(connection: connection)
    auditEvents = SQLiteAuditEventRepository(connection: connection)
  }

  public static func openDefault() throws -> BlueprintDatabase {
    let layout = try StorageLayout.applicationSupport()
    try layout.createDirectories()
    return try BlueprintDatabase(
      databaseURL: layout.databaseURL,
      backupHook: FileMigrationBackupHook(backupDirectory: layout.automaticBackupDirectory)
    )
  }

  public func createInitialSetup(
    profile: BusinessProfile,
    fiscalYear: FiscalYear,
    at date: Date
  ) throws {
    try connection.transaction {
      guard try profiles.fetchAll().isEmpty else {
        throw RepositoryError.duplicate("Initial setup already exists")
      }
      try fiscalYears.save(fiscalYear)
      try profiles.save(profile)
      try accounts.seedStandardAccounts(createdAt: date)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "FiscalYear",
          targetID: fiscalYear.id.uuidString.lowercased()
        )
      )
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
      for account in StandardChartOfAccounts.accounts(createdAt: date) {
        try auditEvents.append(
          AuditEvent(
            occurredAt: date,
            actorKind: .system,
            action: .created,
            targetType: "Account",
            targetID: account.id.uuidString.lowercased(),
            reason: "standard-chart"
          )
        )
      }
    }
  }

  public func saveProfile(_ profile: BusinessProfile, at date: Date) throws {
    try connection.transaction {
      let exists = try profiles.fetch(id: profile.id) != nil
      try profiles.save(profile)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: exists ? .updated : .created,
          targetType: "BusinessProfile",
          targetID: profile.id.uuidString.lowercased()
        )
      )
    }
  }

  public func saveAccount(_ account: Account, at date: Date) throws {
    try connection.transaction {
      let exists = try accounts.fetchAll(includeInactive: true).contains { $0.id == account.id }
      try accounts.save(account)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: exists ? .updated : .created,
          targetType: "Account",
          targetID: account.id.uuidString.lowercased()
        )
      )
    }
  }

  public func deactivateAccount(id: EntityID, at date: Date) throws {
    try connection.transaction {
      try accounts.deactivate(id: id, at: date)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .deactivated,
          targetType: "Account",
          targetID: id.uuidString.lowercased()
        )
      )
    }
  }

  public func lockFiscalYear(id: EntityID, at date: Date) throws {
    try connection.transaction {
      guard var fiscalYear = try fiscalYears.fetch(id: id) else { throw RepositoryError.notFound }
      fiscalYear.lock(at: date)
      try fiscalYears.save(fiscalYear)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .fiscalYearLocked,
          targetType: "FiscalYear",
          targetID: id.uuidString.lowercased()
        )
      )
    }
  }

  public func reopenFiscalYear(id: EntityID, reason: String, at date: Date) throws {
    try connection.transaction {
      guard var fiscalYear = try fiscalYears.fetch(id: id) else { throw RepositoryError.notFound }
      try fiscalYear.reopen(reason: reason, at: date)
      try fiscalYears.save(fiscalYear)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .fiscalYearReopened,
          targetType: "FiscalYear",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
    }
  }

  public func isSetupComplete() throws -> Bool {
    let hasProfile = try !profiles.fetchAll().isEmpty
    let hasFiscalYear = try !fiscalYears.fetchAll().isEmpty
    return hasProfile && hasFiscalYear
  }
}
