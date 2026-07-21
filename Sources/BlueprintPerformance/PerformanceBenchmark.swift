import BlueprintClosing
import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import BlueprintPersistence
import Darwin
import Foundation

public struct PerformanceMetric: Codable, Equatable, Sendable {
  public let name: String
  public let seconds: Double
  public let targetSeconds: Double
  public let passed: Bool

  public init(name: String, seconds: Double, targetSeconds: Double) {
    self.name = name
    self.seconds = seconds
    self.targetSeconds = targetSeconds
    passed = seconds <= targetSeconds
  }
}

public struct PerformanceReport: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let appVersion: String
  public let journalEntries: Int
  public let journalLines: Int
  public let evidenceRecords: Int
  public let peakResidentBytes: Int64
  public let metrics: [PerformanceMetric]

  public init(
    generatedAt: Date,
    appVersion: String,
    journalEntries: Int,
    journalLines: Int,
    evidenceRecords: Int,
    peakResidentBytes: Int64,
    metrics: [PerformanceMetric]
  ) {
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.journalEntries = journalEntries
    self.journalLines = journalLines
    self.evidenceRecords = evidenceRecords
    self.peakResidentBytes = peakResidentBytes
    self.metrics = metrics
  }

  public var passed: Bool { metrics.allSatisfy(\.passed) }
}

public enum PerformanceBenchmark {
  public static let entryCount = 50_000
  public static let journalLineCount = 100_000
  public static let evidenceCount = 20_000

  private static let fiscalYearID = "90000000-0000-4000-8000-000000000001"

  public static func createFixture(at databaseURL: URL) throws {
    let database = try BlueprintDatabase(databaseURL: databaseURL)
    guard try database.fiscalYears.fetchAll().isEmpty else { return }
    let now = Date(timeIntervalSince1970: 1_735_689_600)
    let fiscalYear = try FiscalYear(
      metadata: EntityMetadata(
        id: UUID(uuidString: fiscalYearID)!, createdAt: now, updatedAt: now),
      calendarYear: 2025,
      taxRuleSetID: BlueprintVersions.taxRuleSet,
      formRuleSetID: BlueprintVersions.formRuleSet
    )
    let profile = BusinessProfile(
      metadata: EntityMetadata(createdAt: now),
      fiscalYearID: fiscalYear.id,
      ownerName: "性能試験事業者",
      tradeName: "Blue-Print 性能試験",
      bookkeepingStyle: .doubleEntry,
      consumptionTaxStatus: .generalTaxation,
      invoiceRegistrationStatus: .qualified,
      taxAccountingMethod: .taxExclusive,
      roundingRule: .down
    )
    try database.createInitialSetup(profile: profile, fiscalYear: fiscalYear, at: now)
    let accounts = try database.accounts.fetchAll(includeInactive: false)
    guard let debitAccount = accounts.first(where: { $0.category == .asset }),
      let creditAccount = accounts.first(where: { $0.category == .revenue })
    else { throw RepositoryError.invalidData("Performance accounts are unavailable") }

    try database.connection.transaction {
      try database.connection.execute(
        """
        WITH RECURSIVE seq(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM seq WHERE x < ?)
        INSERT INTO journal_entries(
          id, fiscal_year_id, transaction_date, description, kind, status,
          source_entry_id, reason, posted_at, created_at, updated_at
        )
        SELECT printf('10000000-0000-4000-8000-%012x', x), ?, ? + (x % 365) * 86400,
          '性能テスト-' || x, 'standard', 'posted', NULL, NULL, ?, ?, ?
        FROM seq
        """,
        bindings: [
          .integer(Int64(entryCount)), .text(fiscalYearID), .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      try database.connection.execute(
        """
        INSERT INTO journal_lines(
          id, entry_id, account_id, sub_account_id, side, amount_yen, tax_rate,
          invoice_status, deductible_basis_points, rounding_unit, counterparty, memo, line_order
        )
        SELECT printf('20000000-0000-4000-8000-%012x', rowid), id, ?, NULL, 'debit',
          1000 + (rowid % 100000), 'standard10', 'qualified', 10000, 'line',
          '性能取引先-' || rowid, '', 0
        FROM journal_entries WHERE fiscal_year_id = ?
        """,
        bindings: [.text(debitAccount.id.uuidString.lowercased()), .text(fiscalYearID)]
      )
      try database.connection.execute(
        """
        INSERT INTO journal_lines(
          id, entry_id, account_id, sub_account_id, side, amount_yen, tax_rate,
          invoice_status, deductible_basis_points, rounding_unit, counterparty, memo, line_order
        )
        SELECT printf('30000000-0000-4000-8000-%012x', rowid), id, ?, NULL, 'credit',
          1000 + (rowid % 100000), 'standard10', 'qualified', 10000, 'line',
          '性能取引先-' || rowid, '', 1
        FROM journal_entries WHERE fiscal_year_id = ?
        """,
        bindings: [.text(creditAccount.id.uuidString.lowercased()), .text(fiscalYearID)]
      )
      try database.connection.execute(
        """
        WITH RECURSIVE seq(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM seq WHERE x < ?)
        INSERT INTO evidence_documents(
          id, original_sha256, original_relative_path, original_filename, mime_type,
          byte_count, acquired_at, origin, state, transaction_date, amount_yen,
          counterparty, electronic_transaction, created_at, updated_at
        )
        SELECT printf('40000000-0000-4000-8000-%012x', x), printf('%064x', x),
          'Originals/performance-' || x || '.pdf', 'performance-' || x || '.pdf',
          'application/pdf', 1024, ? + (x % 365) * 86400,
          CASE WHEN x % 2 = 0 THEN 'electronicTransaction' ELSE 'paperScan' END,
          'needsReview', ? + (x % 365) * 86400, 1000 + (x % 100000),
          '性能取引先-' || x, x % 2, ?, ?
        FROM seq
        """,
        bindings: [
          .integer(Int64(evidenceCount)), .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
    }
    try database.connection.execute("ANALYZE")
    try database.connection.checkpoint()
  }

  public static func run(databaseURL: URL) throws -> PerformanceReport {
    var metrics: [PerformanceMetric] = []
    let (database, opening) = try timed { try BlueprintDatabase(databaseURL: databaseURL) }
    metrics.append(PerformanceMetric(name: "database-open", seconds: opening, targetSeconds: 3))
    guard let fiscalYear = try database.fiscalYears.fetchAll().first else {
      throw RepositoryError.notFound
    }

    let (journalSearch, searchTime) = try timed {
      try database.journals.search(
        JournalSearch(fiscalYearID: fiscalYear.id, text: "性能テスト-49999"))
    }
    guard journalSearch.count == 1 else {
      throw RepositoryError.invalidData("Journal search fixture mismatch")
    }
    metrics.append(PerformanceMetric(name: "journal-search", seconds: searchTime, targetSeconds: 1))

    let (evidenceSearch, evidenceTime) = try timed {
      try database.evidence.search(EvidenceSearch(counterparty: "性能取引先-19999"))
    }
    guard evidenceSearch.count == 1 else {
      throw RepositoryError.invalidData("Evidence search fixture mismatch")
    }
    metrics.append(
      PerformanceMetric(name: "evidence-search", seconds: evidenceTime, targetSeconds: 1))

    let (entries, loadTime) = try timed {
      try database.journals.search(JournalSearch(fiscalYearID: fiscalYear.id))
    }
    metrics.append(
      PerformanceMetric(name: "major-screen-data", seconds: loadTime, targetSeconds: 3))

    let (_, trialTime) = try timed { try AccountingReports.trialBalance(entries: entries) }
    metrics.append(
      PerformanceMetric(name: "monthly-trial-balance", seconds: trialTime, targetSeconds: 5))

    let accounts = try database.accounts.fetchAll(includeInactive: false)
    let calendar = Calendar(identifier: .gregorian)
    let periodStart = calendar.date(
      from: DateComponents(year: fiscalYear.calendarYear, month: 1, day: 1))!
    let periodEnd = calendar.date(
      from: DateComponents(
        year: fiscalYear.calendarYear, month: 12, day: 31, hour: 23, minute: 59,
        second: 59))!
    let period = periodStart...periodEnd
    let (_, closingTime) = try timed {
      _ = try ClosingReports.profitAndLoss(entries: entries, accounts: accounts, period: period)
      return try ClosingReports.balanceSheet(
        entries: entries, accounts: accounts, fiscalYearPeriod: period,
        asOf: period.upperBound)
    }
    metrics.append(
      PerformanceMetric(
        name: "annual-financial-statements", seconds: closingTime, targetSeconds: 10))

    let csv = makeCSV(rows: 10_000)
    let profile = ImportProfile(
      name: "performance", sourceKind: .bankCSV, encoding: .utf8, delimiter: .comma,
      hasHeader: true,
      mapping: ImportColumnMapping(dateColumn: 0, amountColumn: 1, descriptionColumn: 2),
      updatedAt: Date())
    let (batch, csvTime) = try timed {
      try CSVImporter.makeBatch(
        data: csv, filename: "performance.csv", profile: profile, existing: [],
        importedAt: Date())
    }
    guard batch.transactions.count == 10_000 else {
      throw RepositoryError.invalidData("CSV fixture mismatch")
    }
    metrics.append(
      PerformanceMetric(name: "csv-preview-10000", seconds: csvTime, targetSeconds: 60))

    return PerformanceReport(
      generatedAt: Date(), appVersion: BlueprintVersions.app, journalEntries: entryCount,
      journalLines: journalLineCount, evidenceRecords: evidenceCount,
      peakResidentBytes: peakResidentBytes(), metrics: metrics)
  }

  private static func makeCSV(rows: Int) -> Data {
    var text = "date,amount,description\n"
    text.reserveCapacity(rows * 40)
    for row in 1...rows { text += "2025/01/01,\(row),性能CSV-\(row)\n" }
    return Data(text.utf8)
  }

  private static func timed<T>(_ work: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let value = try work()
    return (value, start.duration(to: .now).seconds)
  }

  private static func peakResidentBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
  }
}

extension Duration {
  fileprivate var seconds: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
  }
}
