import Foundation

public enum RepositoryError: Error, Equatable, Sendable {
  case notFound
  case duplicate(String)
  case physicalDeletionForbidden
  case fiscalYearLocked
  case invalidData(String)
}

public protocol BusinessProfileRepository: Sendable {
  func save(_ profile: BusinessProfile) throws
  func fetch(id: EntityID) throws -> BusinessProfile?
  func fetchAll() throws -> [BusinessProfile]
}

public protocol FiscalYearRepository: Sendable {
  func save(_ fiscalYear: FiscalYear) throws
  func fetch(id: EntityID) throws -> FiscalYear?
  func fetch(calendarYear: Int) throws -> FiscalYear?
  func fetchAll() throws -> [FiscalYear]
}

public protocol AccountRepository: Sendable {
  func save(_ account: Account) throws
  func seedStandardAccounts(createdAt: Date) throws
  func fetchAll(includeInactive: Bool) throws -> [Account]
  func deactivate(id: EntityID, at date: Date) throws
  func delete(id: EntityID) throws
}

public protocol JournalRepository: Sendable {
  func saveDraft(_ entry: JournalEntry) throws
  func post(id: EntityID, fiscalYear: FiscalYear, at date: Date) throws
  func fetch(id: EntityID) throws -> JournalEntry?
  func search(_ query: JournalSearch) throws -> [JournalEntry]
  func delete(id: EntityID) throws
}
