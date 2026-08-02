import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import CryptoKit
import Foundation

public struct V2ImportResult: Sendable {
  public let candidates: [StoredImportCandidateV2]
  public let quarantinedRowCount: Int
  public let job: JobRecord
}

public struct V2MatchingResult: Sendable {
  public let candidates: [MatchCandidateV2]
  public let job: JobRecord
}

public struct V2ImportMatchingService: Sendable {
  public init() {}

  public func importCSV(
    data: Data,
    filename: String,
    profile: ImportProfile,
    database: V2Database,
    at date: Date = Date()
  ) async throws -> V2ImportResult {
    let fileHash = Self.sha256(data)
    let key = "import:\(fileHash)"
    if let existingJob = try await database.jobs().first(where: {
      $0.idempotencyKey == key && $0.state == .succeeded
    }) {
      return V2ImportResult(
        candidates: try await database.importCandidates(),
        quarantinedRowCount: 0,
        job: existingJob
      )
    }
    let job = JobRecord(
      idempotencyKey: key,
      kind: .dataImport,
      createdAt: date,
      updatedAt: date
    )
    try await database.enqueue(job)
    let storedJob = try await database.jobs().first { $0.idempotencyKey == key } ?? job
    do {
      if storedJob.state == .failed {
        try await database.updateJob(
          id: storedJob.id,
          state: .queued,
          progressBasisPoints: storedJob.progressBasisPoints,
          checkpoint: storedJob.checkpoint,
          at: date
        )
      }
      try await database.updateJob(
        id: storedJob.id,
        state: .running,
        progressBasisPoints: 1_000,
        checkpoint: "source-authenticated:\(fileHash)",
        at: date
      )
      let existing = try await database.importCandidates().compactMap {
        Self.importedTransaction(from: $0)
      }
      let batch = try CSVImporter.makeBatch(
        data: data,
        filename: filename,
        profile: profile,
        existing: existing,
        importedAt: date
      )
      let candidates = batch.transactions.map { transaction in
        var warnings: [String] = []
        if transaction.duplicateOfID != nil {
          warnings.append("同一キーの取込候補が既に存在します")
        }
        return StoredImportCandidateV2(
          candidate: ImportCandidateV1(
            id: transaction.id,
            sourceKind: profile.sourceKind.rawValue,
            sourceFingerprint: Self.sha256(Data(transaction.duplicateKey.utf8)),
            occurredAt: transaction.transactionDate,
            amountYen: transaction.amount.yen,
            description: transaction.description,
            warnings: warnings
          ),
          state: transaction.duplicateOfID == nil ? .pending : .excluded,
          createdAt: date,
          updatedAt: date
        )
      }
      try await database.saveImportCandidates(candidates)
      for candidate in candidates where candidate.state == .pending {
        _ = try await GenerateRuleCandidateUseCase(repository: database).execute(
          importCandidate: candidate.candidate,
          at: date
        )
      }
      try await database.updateJob(
        id: storedJob.id,
        state: .succeeded,
        progressBasisPoints: 10_000,
        checkpoint:
          "candidates:\(candidates.count);quarantined:\(batch.errors.count)",
        failureReason: batch.errors.isEmpty
          ? nil
          : "\(batch.errors.count)行を解釈できず隔離しました",
        at: Date()
      )
      let completed = try await database.jobs().first { $0.id == storedJob.id } ?? storedJob
      return V2ImportResult(
        candidates: candidates,
        quarantinedRowCount: batch.errors.count,
        job: completed
      )
    } catch {
      try? await database.updateJob(
        id: storedJob.id,
        state: .failed,
        progressBasisPoints: 1_000,
        checkpoint: "source-authenticated:\(fileHash)",
        failureReason: String(describing: error),
        at: Date()
      )
      throw error
    }
  }

  public func generateMatches(
    database: V2Database,
    at date: Date = Date()
  ) async throws -> V2MatchingResult {
    let imports = try await database.importCandidates(state: .pending)
    let evidence = try await database.evidenceDocuments()
    let rules = try await database.journalRules()
    let keyMaterial =
      imports.map(\.candidate.sourceFingerprint).sorted().joined(separator: "|")
      + evidence.map(\.originalSHA256).sorted().joined(separator: "|")
      + rules.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
      .sorted().joined(separator: "|")
    let key = "matching:\(Self.sha256(Data(keyMaterial.utf8)))"
    if let existingJob = try await database.jobs().first(where: {
      $0.idempotencyKey == key && $0.state == .succeeded
    }) {
      return V2MatchingResult(
        candidates: try await database.matchCandidates(),
        job: existingJob
      )
    }
    let job = JobRecord(
      idempotencyKey: key,
      kind: .matching,
      createdAt: date,
      updatedAt: date
    )
    try await database.enqueue(job)
    let storedJob = try await database.jobs().first { $0.idempotencyKey == key } ?? job
    do {
      if storedJob.state == .failed {
        try await database.updateJob(
          id: storedJob.id,
          state: .queued,
          progressBasisPoints: storedJob.progressBasisPoints,
          checkpoint: storedJob.checkpoint,
          at: date
        )
      }
      try await database.updateJob(
        id: storedJob.id,
        state: .running,
        progressBasisPoints: 1_000,
        checkpoint: "inputs-loaded",
        at: date
      )
      for imported in imports {
        _ = try await GenerateRuleCandidateUseCase(repository: database).execute(
          importCandidate: imported.candidate,
          at: date
        )
      }
      let journalCandidates = try await database.journalCandidates()
      var matches: [MatchCandidateV2] = []
      for imported in imports {
        guard
          let occurredAt = imported.candidate.occurredAt,
          let amount = imported.candidate.amountYen
        else { continue }
        for document in evidence {
          let values = try await Self.matchValues(document: document, database: database)
          guard
            let evidenceDate = values.date,
            let evidenceAmount = values.amount,
            Calendar(identifier: .gregorian).isDate(evidenceDate, inSameDayAs: occurredAt),
            Swift.abs(evidenceAmount) == Swift.abs(amount)
          else { continue }
          var confidence = 7_500
          var explanation = "日付と金額が一致"
          if let counterparty = values.counterparty,
            !counterparty.isEmpty,
            imported.candidate.description.localizedCaseInsensitiveContains(counterparty)
          {
            confidence = 10_000
            explanation += "、取引先も一致"
          }
          let journalCandidate = journalCandidates.first {
            $0.sourceID == imported.id && $0.state == .pending
          }
          let match = MatchCandidateV2(
            idempotencyKey:
              "match:\(imported.id.uuidString.lowercased()):\(document.id.uuidString.lowercased())",
            importCandidateID: imported.id,
            evidenceID: document.id,
            journalCandidateID: journalCandidate?.id,
            confidenceBasisPoints: confidence,
            explanation: explanation,
            createdAt: date,
            updatedAt: date
          )
          try await database.saveMatchCandidate(match)
          matches.append(match)
        }
      }
      try await database.updateJob(
        id: storedJob.id,
        state: .succeeded,
        progressBasisPoints: 10_000,
        checkpoint: "match-candidates:\(matches.count)",
        at: Date()
      )
      let completed = try await database.jobs().first { $0.id == storedJob.id } ?? storedJob
      return V2MatchingResult(candidates: matches, job: completed)
    } catch {
      try? await database.updateJob(
        id: storedJob.id,
        state: .failed,
        progressBasisPoints: 1_000,
        checkpoint: "inputs-loaded",
        failureReason: String(describing: error),
        at: Date()
      )
      throw error
    }
  }

  private static func importedTransaction(
    from stored: StoredImportCandidateV2
  ) -> ImportedTransaction? {
    guard
      let date = stored.candidate.occurredAt,
      let amount = stored.candidate.amountYen
    else { return nil }
    return ImportedTransaction(
      id: stored.id,
      batchID: UUID(),
      rowNumber: 0,
      transactionDate: date,
      amount: Money(yen: amount),
      description: stored.candidate.description,
      state: stored.state == .excluded ? .excluded : .unprocessed
    )
  }

  private static func matchValues(
    document: EvidenceDocument,
    database: V2Database
  ) async throws -> (date: Date?, amount: Int64?, counterparty: String?) {
    if document.transactionDate != nil || document.amount != nil || document.counterparty != nil {
      return (document.transactionDate, document.amount?.yen, document.counterparty)
    }
    let candidates = try await database.ocrCandidates(evidenceID: document.id)
    let date = candidates.first { $0.field == .transactionDate }
      .flatMap { parseDate($0.correctedValue ?? $0.rawValue) }
    let amount = candidates.first { $0.field == .amount }
      .flatMap { parseAmount($0.correctedValue ?? $0.rawValue) }
    let counterparty = candidates.first { $0.field == .counterparty }
      .map { $0.correctedValue ?? $0.rawValue }
    return (date, amount, counterparty)
  }

  private static func parseDate(_ value: String) -> Date? {
    for format in ["yyyy/MM/dd", "yyyy-MM-dd", "yyyy年M月d日"] {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "ja_JP_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }

  private static func parseAmount(_ value: String) -> Int64? {
    let normalized = value.filter { $0.isNumber || $0 == "-" }
    return Int64(normalized)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
