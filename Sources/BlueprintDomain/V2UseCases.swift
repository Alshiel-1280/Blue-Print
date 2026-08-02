import Foundation

public protocol V2CoreRepository: Sendable {
  func createInitialSetup(
    profile: BusinessProfile,
    fiscalYear: FiscalYear,
    at date: Date
  ) async throws
  func profiles() async throws -> [BusinessProfile]
  func fiscalYears() async throws -> [FiscalYear]
  func accounts(includeInactive: Bool) async throws -> [Account]
  func saveProfile(_ profile: BusinessProfile) async throws
  func saveJournalDraft(_ entry: JournalEntry) async throws
  func postJournal(id: UUID, fiscalYear: FiscalYear, at date: Date) async throws
  func journalEntries(fiscalYearID: UUID?) async throws -> [JournalEntry]
}

public struct V2WorkspaceSnapshot: Equatable, Sendable {
  public let profile: BusinessProfile?
  public let fiscalYear: FiscalYear?
  public let accounts: [Account]
  public let journalEntries: [JournalEntry]

  public init(
    profile: BusinessProfile?,
    fiscalYear: FiscalYear?,
    accounts: [Account],
    journalEntries: [JournalEntry]
  ) {
    self.profile = profile
    self.fiscalYear = fiscalYear
    self.accounts = accounts
    self.journalEntries = journalEntries
  }
}

public struct LoadV2WorkspaceUseCase: Sendable {
  private let repository: any V2CoreRepository

  public init(repository: any V2CoreRepository) {
    self.repository = repository
  }

  public func execute() async throws -> V2WorkspaceSnapshot {
    let profiles = try await repository.profiles()
    let fiscalYears = try await repository.fiscalYears()
    let fiscalYear = fiscalYears.max { $0.calendarYear < $1.calendarYear }
    async let accounts = repository.accounts(includeInactive: false)
    async let entries = repository.journalEntries(fiscalYearID: fiscalYear?.id)
    return try await V2WorkspaceSnapshot(
      profile: profiles.first { $0.fiscalYearID == fiscalYear?.id } ?? profiles.first,
      fiscalYear: fiscalYear,
      accounts: accounts,
      journalEntries: entries
    )
  }
}

public struct PostV2JournalUseCase: Sendable {
  private let repository: any V2CoreRepository

  public init(repository: any V2CoreRepository) {
    self.repository = repository
  }

  public func execute(
    entry: JournalEntry,
    fiscalYear: FiscalYear,
    at date: Date
  ) async throws {
    try await repository.saveJournalDraft(entry)
    try await repository.postJournal(id: entry.id, fiscalYear: fiscalYear, at: date)
  }
}
