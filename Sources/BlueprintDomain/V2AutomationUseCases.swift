import Foundation

public protocol V2AutomationRepository: Sendable {
  func journalTemplates() async throws -> [JournalTemplateV2]
  func journalRules() async throws -> [JournalRuleV2]
  func recurringJournals(dueAt date: Date?) async throws -> [RecurringJournalV2]
  func saveJournalCandidate(_ candidate: JournalCandidateV2) async throws
  func journalCandidates(state: JournalCandidateStateV2?) async throws -> [JournalCandidateV2]
  func markJournalCandidate(
    id: UUID,
    state: JournalCandidateStateV2,
    journalEntryID: UUID?,
    at date: Date
  ) async throws
  func advanceRecurringJournal(id: UUID, nextRunAt: Date, at date: Date) async throws
}

public struct GenerateRecurringCandidatesUseCase: Sendable {
  private let repository: any V2AutomationRepository

  public init(repository: any V2AutomationRepository) {
    self.repository = repository
  }

  @discardableResult
  public func execute(dueAt date: Date) async throws -> [JournalCandidateV2] {
    let templates = try await repository.journalTemplates()
    let schedules = try await repository.recurringJournals(dueAt: date)
    var generated: [JournalCandidateV2] = []
    for schedule in schedules {
      guard let template = templates.first(where: { $0.id == schedule.templateID && $0.isActive })
      else { continue }
      let candidate = JournalCandidateV2(
        idempotencyKey:
          "recurring:\(schedule.id.uuidString.lowercased()):\(Int(schedule.nextRunAt.timeIntervalSince1970))",
        sourceKind: "recurring",
        sourceID: schedule.id,
        transactionDate: schedule.nextRunAt,
        description: template.defaultDescription,
        amountYen: schedule.amountYen,
        debitAccountID: template.debitAccountID,
        creditAccountID: template.creditAccountID,
        taxRate: template.taxRate,
        invoiceStatus: template.invoiceStatus,
        confidenceBasisPoints: 10_000,
        explanation: "定期仕訳「\(template.name)」から生成",
        createdAt: date,
        updatedAt: date
      )
      try await repository.saveJournalCandidate(candidate)
      let component: Calendar.Component =
        schedule.frequency == .monthly ? .month : .year
      let next =
        Calendar(identifier: .gregorian).date(
          byAdding: component,
          value: 1,
          to: schedule.nextRunAt
        ) ?? schedule.nextRunAt.addingTimeInterval(31 * 86_400)
      try await repository.advanceRecurringJournal(id: schedule.id, nextRunAt: next, at: date)
      generated.append(candidate)
    }
    return generated
  }
}

public struct ConfirmJournalCandidateUseCase: Sendable {
  private let repository: any V2CoreRepository & V2AutomationRepository

  public init(repository: any V2CoreRepository & V2AutomationRepository) {
    self.repository = repository
  }

  @discardableResult
  public func execute(
    candidate: JournalCandidateV2,
    fiscalYear: FiscalYear,
    at date: Date
  ) async throws -> JournalEntry {
    guard candidate.state == .pending else {
      throw V2AutomationError.candidateAlreadyResolved
    }
    let entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYear.id,
      transactionDate: candidate.transactionDate,
      description: candidate.description,
      lines: [
        try JournalLine(
          accountID: candidate.debitAccountID,
          side: .debit,
          amount: Money(yen: candidate.amountYen),
          taxRate: candidate.taxRate,
          invoiceStatus: candidate.invoiceStatus
        ),
        try JournalLine(
          accountID: candidate.creditAccountID,
          side: .credit,
          amount: Money(yen: candidate.amountYen)
        ),
      ]
    )
    try await repository.saveJournalDraft(entry)
    try await repository.postJournal(id: entry.id, fiscalYear: fiscalYear, at: date)
    try await repository.markJournalCandidate(
      id: candidate.id,
      state: .confirmed,
      journalEntryID: entry.id,
      at: date
    )
    return entry
  }
}

public enum V2AutomationError: Error, Equatable, Sendable {
  case candidateAlreadyResolved
}

public struct GenerateRuleCandidateUseCase: Sendable {
  private let repository: any V2AutomationRepository

  public init(repository: any V2AutomationRepository) {
    self.repository = repository
  }

  public func execute(
    importCandidate: ImportCandidateV1,
    at date: Date
  ) async throws -> JournalCandidateV2? {
    guard let occurredAt = importCandidate.occurredAt,
      let amount = importCandidate.amountYen,
      amount != 0
    else { return nil }
    let normalized = importCandidate.description.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
    let rule = try await repository.journalRules()
      .filter(\.isActive)
      .sorted { $0.priority < $1.priority }
      .first {
        normalized.contains(
          $0.descriptionContains.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
          )
        )
      }
    guard let rule else { return nil }
    let candidate = JournalCandidateV2(
      idempotencyKey:
        "rule:\(rule.id.uuidString.lowercased()):\(importCandidate.sourceFingerprint)",
      sourceKind: "import-rule",
      sourceID: importCandidate.id,
      transactionDate: occurredAt,
      description: importCandidate.description,
      amountYen: Swift.abs(amount),
      debitAccountID: amount < 0 ? rule.debitAccountID : rule.creditAccountID,
      creditAccountID: amount < 0 ? rule.creditAccountID : rule.debitAccountID,
      taxRate: rule.taxRate,
      confidenceBasisPoints: 8_000,
      explanation: "仕訳ルール「\(rule.name)」に一致",
      createdAt: date,
      updatedAt: date
    )
    try await repository.saveJournalCandidate(candidate)
    return candidate
  }
}
