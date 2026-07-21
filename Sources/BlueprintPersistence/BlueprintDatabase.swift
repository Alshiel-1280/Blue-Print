import BlueprintAudit
import BlueprintDomain
import Foundation

public final class BlueprintDatabase: @unchecked Sendable {
  public let connection: SQLiteConnection
  public let profiles: SQLiteBusinessProfileRepository
  public let fiscalYears: SQLiteFiscalYearRepository
  public let accounts: SQLiteAccountRepository
  public let journals: SQLiteJournalRepository
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
    journals = SQLiteJournalRepository(connection: connection)
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
      guard try fiscalYears.fetch(id: profile.fiscalYearID)?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
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
      guard try fiscalYears.fetchAll().first?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
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
      guard try fiscalYears.fetchAll().first?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
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

  public func saveJournalDraft(_ entry: JournalEntry, at date: Date) throws {
    try connection.transaction {
      guard try fiscalYears.fetch(id: entry.fiscalYearID)?.status != .locked else {
        throw RepositoryError.fiscalYearLocked
      }
      if let existing = try journals.fetch(id: entry.id), existing.status == .posted {
        throw JournalError.cannotModifyPostedEntry
      }
      guard entry.status == .draft || entry.status == .pendingReview else {
        throw JournalError.cannotModifyPostedEntry
      }
      try journals.persist(entry)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .created,
          targetType: "JournalEntry",
          targetID: entry.id.uuidString.lowercased()
        )
      )
    }
  }

  public func postJournal(id: EntityID, fiscalYearID: EntityID, at date: Date) throws {
    try connection.transaction {
      guard let fiscalYear = try fiscalYears.fetch(id: fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard var entry = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      try entry.post(for: fiscalYear, at: date)
      try journals.persist(entry)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .updated,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: "posted"
        )
      )
    }
  }

  @discardableResult
  public func reverseJournal(id: EntityID, reason: String, at date: Date) throws -> JournalEntry {
    try connection.transaction {
      guard var original = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      guard let fiscalYear = try fiscalYears.fetch(id: original.fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
      var reversal = try original.makeReversal(at: date, reason: reason)
      try reversal.post(for: fiscalYear, at: date)
      original.status = .reversed
      original.metadata.touch(at: date)
      try journals.persist(original)
      try journals.persist(reversal)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .cancelled,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
      return reversal
    }
  }

  @discardableResult
  public func correctJournal(
    id: EntityID,
    transactionDate: Date,
    description: String,
    lines: [JournalLine],
    reason: String,
    at date: Date
  ) throws -> (reversal: JournalEntry, correction: JournalEntry) {
    try connection.transaction {
      guard var original = try journals.fetch(id: id) else { throw RepositoryError.notFound }
      guard let fiscalYear = try fiscalYears.fetch(id: original.fiscalYearID) else {
        throw RepositoryError.notFound
      }
      guard fiscalYear.status != .locked else { throw RepositoryError.fiscalYearLocked }
      var reversal = try original.makeReversal(at: date, reason: reason)
      var correction = try original.makeCorrection(
        metadata: EntityMetadata(createdAt: date),
        transactionDate: transactionDate,
        description: description,
        lines: lines,
        reason: reason
      )
      try reversal.post(for: fiscalYear, at: date)
      try correction.post(for: fiscalYear, at: date)
      original.status = .corrected
      original.metadata.touch(at: date)
      try journals.persist(original)
      try journals.persist(reversal)
      try journals.persist(correction)
      try auditEvents.append(
        AuditEvent(
          occurredAt: date,
          actorKind: .localUser,
          action: .corrected,
          targetType: "JournalEntry",
          targetID: id.uuidString.lowercased(),
          reason: reason
        )
      )
      return (reversal, correction)
    }
  }

  public func isSetupComplete() throws -> Bool {
    let hasProfile = try !profiles.fetchAll().isEmpty
    let hasFiscalYear = try !fiscalYears.fetchAll().isEmpty
    return hasProfile && hasFiscalYear
  }
}
