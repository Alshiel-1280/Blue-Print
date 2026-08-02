import BlueprintClosing
import BlueprintDomain
import BlueprintETax
import BlueprintFiling
import BlueprintTax
import CryptoKit
import Foundation

public enum V2XTXGenerationError: Error, Equatable, Sendable {
  case unsupportedYear(Int)
  case invalidFiscalYear
  case validationFailed([String])
  case generatedOutputMissing
}

extension V2XTXGenerationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedYear(let year):
      return "\(year)年の所得税帳票・XTXルールはまだ有効化されていません。"
    case .invalidFiscalYear:
      return "対象年度の開始日と終了日を計算できません。"
    case .validationFailed(let messages):
      return messages.joined(separator: "\n")
    case .generatedOutputMissing:
      return "生成済みXTXが見つかりません。申告内容を確認して再生成してください。"
    }
  }
}

public struct V2XTXGenerationResult: Sendable {
  public let package: ETaxGeneratedPackage
  public let durableURL: URL
  public let jobID: UUID

  public init(package: ETaxGeneratedPackage, durableURL: URL, jobID: UUID) {
    self.package = package
    self.durableURL = durableURL
    self.jobID = jobID
  }
}

public struct V2XTXService: Sendable {
  public init() {}

  public func generate(
    profile: BusinessProfile,
    fiscalYear: FiscalYear,
    accounts: [Account],
    journalEntries: [JournalEntry],
    ruleStore: RuleCatalogStore,
    database: V2Database,
    at requestedAt: Date = Date(),
    fileManager: FileManager = .default
  ) async throws -> V2XTXGenerationResult {
    guard
      ruleStore.support(for: fiscalYear.calendarYear)?.supports(.incomeTaxForm) == true,
      ruleStore.support(for: fiscalYear.calendarYear)?.supports(.xtx) == true
    else {
      throw V2XTXGenerationError.unsupportedYear(fiscalYear.calendarYear)
    }

    let taxRules = try ruleStore.taxRule(for: fiscalYear.calendarYear)
    let formRules = try ruleStore.formRule(for: fiscalYear.calendarYear)
    let fingerprint = XTXGenerator.ledgerFingerprint(parts: [
      "v2-xtx-1",
      String(fiscalYear.calendarYear),
      taxRules.id,
      formRules.id,
      profile.id.uuidString.lowercased(),
      String(profile.metadata.updatedAt.timeIntervalSince1970),
      journalEntries
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map {
          "\($0.id.uuidString.lowercased())|\($0.metadata.updatedAt.timeIntervalSince1970)"
        }
        .joined(separator: ","),
    ])
    let idempotencyKey = "xtx:\(fingerprint)"
    var job = try await database.jobs().first { $0.idempotencyKey == idempotencyKey }
    if job == nil {
      let newJob = JobRecord(
        idempotencyKey: idempotencyKey,
        kind: .xtxGeneration,
        createdAt: requestedAt,
        updatedAt: requestedAt
      )
      try await database.enqueue(newJob)
      job = try await database.jobs().first { $0.idempotencyKey == idempotencyKey }
    }
    guard var job else { throw RepositoryError.notFound }

    let isRepairingMissingOutput: Bool
    if job.state == .succeeded {
      if let checkpoint = job.checkpoint {
        let outputURL = database.layout.jobsDirectory.appendingPathComponent(checkpoint)
        if fileManager.fileExists(atPath: outputURL.path) {
          let data = try Data(contentsOf: outputURL)
          return V2XTXGenerationResult(
            package: ETaxGeneratedPackage(
              fileName: outputURL.lastPathComponent,
              data: data,
              hash: Self.sha256(data)
            ),
            durableURL: outputURL,
            jobID: job.id
          )
        }
      }
      // The durable file can be removed independently of the database. Recreate the
      // deterministic output from the same input fingerprint while preserving the
      // succeeded job record and its original generation timestamp.
      isRepairingMissingOutput = true
    } else {
      isRepairingMissingOutput = false
    }

    if !isRepairingMissingOutput, job.state == .failed {
      try await database.updateJob(
        id: job.id,
        state: .queued,
        progressBasisPoints: 0,
        checkpoint: "validation",
        at: requestedAt
      )
      job.state = .queued
    } else if !isRepairingMissingOutput, job.state == .running {
      try await database.updateJob(
        id: job.id,
        state: .queued,
        progressBasisPoints: job.progressBasisPoints,
        checkpoint: job.checkpoint ?? "resuming",
        at: requestedAt
      )
      job.state = .queued
    }

    if !isRepairingMissingOutput {
      try await database.updateJob(
        id: job.id,
        state: .running,
        progressBasisPoints: 1_000,
        checkpoint: "validation",
        at: requestedAt
      )
    }

    do {
      let period = try Self.fiscalYearPeriod(fiscalYear.calendarYear)
      let profitAndLoss = try ClosingReports.profitAndLoss(
        entries: journalEntries,
        accounts: accounts,
        period: period
      )
      let balanceSheet = try ClosingReports.balanceSheet(
        entries: journalEntries,
        accounts: accounts,
        fiscalYearPeriod: period,
        asOf: period.upperBound
      )
      let businessSnapshot = BusinessIncomeSnapshot(
        revenue: profitAndLoss.totalRevenue,
        expenses: profitAndLoss.totalExpenses,
        income: profitAndLoss.profit,
        generatedAt: requestedAt
      )
      let blueReturn = BlueReturnMapper.make(
        fiscalYear: fiscalYear.calendarYear,
        profile: profile,
        profitAndLoss: profitAndLoss,
        balanceSheet: balanceSheet,
        businessSnapshot: businessSnapshot,
        propertyReport: PropertyIncomeReport.make(entries: [])
      )
      let deduction = BlueReturnMapper.deductionAssessment(
        profile: profile,
        balanceSheet: balanceSheet,
        taxRuleSet: taxRules,
        intendsElectronicFiling: true
      )
      let filingSummary = FilingWorkspaceSummary(
        businessIncome: businessSnapshot,
        propertyIncome: .zero,
        wageRevenue: .zero,
        securitiesIncome: .zero,
        otherIncome: .zero,
        withholdingTax: .zero,
        deductions: .zero,
        attentionCount: 0
      )
      let returnData = ETaxMapper.make(
        fiscalYear: fiscalYear.calendarYear,
        profile: profile,
        blueReturn: blueReturn,
        deductionAssessment: deduction,
        filingSummary: filingSummary,
        deductions: [],
        unsupportedCases: [],
        taxRuleSet: taxRules,
        formRuleSet: formRules,
        ledgerFingerprint: fingerprint
      )
      let issues = ETaxValidator.validate(returnData, rules: formRules, blueReturn: blueReturn)
      let errors = issues.filter { $0.severity == .error }.map { $0.message }
      guard errors.isEmpty else {
        throw V2XTXGenerationError.validationFailed(errors)
      }

      if !isRepairingMissingOutput {
        try await database.updateJob(
          id: job.id,
          state: .running,
          progressBasisPoints: 7_500,
          checkpoint: "rendering",
          at: requestedAt
        )
      }
      let package = try XTXGenerator.generate(
        returnData,
        validationIssues: issues,
        generatedAt: job.createdAt
      )
      let directory = database.layout.jobsDirectory.appendingPathComponent(
        "XTX", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let durableName =
        "blue-print-\(fiscalYear.calendarYear)-\(package.hash.prefix(12)).xtx"
      let outputURL = directory.appendingPathComponent(durableName)
      try package.data.write(to: outputURL, options: Data.WritingOptions.atomic)
      let checkpoint = "XTX/\(durableName)"
      try await database.updateJob(
        id: job.id,
        state: .succeeded,
        progressBasisPoints: 10_000,
        checkpoint: checkpoint,
        at: requestedAt
      )
      return V2XTXGenerationResult(
        package: ETaxGeneratedPackage(
          fileName: "blue-print-\(fiscalYear.calendarYear).xtx",
          data: package.data,
          hash: package.hash
        ),
        durableURL: outputURL,
        jobID: job.id
      )
    } catch {
      if !isRepairingMissingOutput {
        try? await database.updateJob(
          id: job.id,
          state: .failed,
          progressBasisPoints: 1_000,
          checkpoint: "validation",
          failureReason: error.localizedDescription,
          at: requestedAt
        )
      }
      throw error
    }
  }

  private static func fiscalYearPeriod(_ calendarYear: Int) throws -> ClosedRange<Date> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    guard
      let start = calendar.date(from: DateComponents(year: calendarYear, month: 1, day: 1)),
      let nextYear = calendar.date(
        from: DateComponents(year: calendarYear + 1, month: 1, day: 1))
    else {
      throw V2XTXGenerationError.invalidFiscalYear
    }
    return start...nextYear.addingTimeInterval(-1)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
