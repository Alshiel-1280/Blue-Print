import BlueprintDomain
import Foundation

public enum FixedAssetError: Error, Equatable, Sendable {
  case invalidCost
  case invalidUsefulLife
  case invalidRate
  case invalidEvent
  case disposalBeforeService
}

public enum DepreciationMethod: String, Codable, CaseIterable, Sendable {
  case straightLine
  case decliningBalance
  case immediateExpense
  case pooledThreeYear
}

public enum FixedAssetStatus: String, Codable, CaseIterable, Sendable {
  case acquired
  case inService
  case disposed
  case retired
}

public enum FixedAssetEventKind: String, Codable, CaseIterable, Sendable {
  case acquired
  case placedInService
  case disposed
  case retired
  case businessUseChanged
}

public struct FixedAssetEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: EntityID
  public let occurredOn: Date
  public let kind: FixedAssetEventKind
  public let businessUseBasisPoints: Int?
  public let proceeds: Money?
  public let note: String

  public init(
    id: EntityID = UUID(),
    occurredOn: Date,
    kind: FixedAssetEventKind,
    businessUseBasisPoints: Int? = nil,
    proceeds: Money? = nil,
    note: String = ""
  ) throws {
    if let businessUseBasisPoints, !(0...10_000).contains(businessUseBasisPoints) {
      throw FixedAssetError.invalidRate
    }
    if let proceeds, proceeds.yen < 0 { throw FixedAssetError.invalidCost }
    self.id = id
    self.occurredOn = occurredOn
    self.kind = kind
    self.businessUseBasisPoints = businessUseBasisPoints
    self.proceeds = proceeds
    self.note = note
  }
}

public struct DepreciationYear: Codable, Equatable, Identifiable, Sendable {
  public let calendarYear: Int
  public let openingBookValue: Money
  public let accountingDepreciation: Money
  public let businessDepreciation: Money
  public let closingBookValue: Money
  public let monthsInService: Int
  public let businessUseBasisPoints: Int

  public var id: Int { calendarYear }
}

public struct FixedAsset: Codable, Equatable, Identifiable, Sendable {
  public var metadata: EntityMetadata
  public let fiscalYearID: EntityID
  public var code: String
  public var name: String
  public var category: String
  public var acquisitionDate: Date
  public var serviceDate: Date
  public var acquisitionCost: Money
  public var usefulLifeYears: Int
  public var method: DepreciationMethod
  public var decliningRateBasisPoints: Int
  public let initialBusinessUseBasisPoints: Int
  public var businessUseBasisPoints: Int
  public var assetAccountID: EntityID
  public var depreciationExpenseAccountID: EntityID
  public var accumulatedDepreciationAccountID: EntityID
  public var status: FixedAssetStatus
  public var events: [FixedAssetEvent]
  public var disposalDate: Date?
  public var disposalProceeds: Money?

  public var id: EntityID { metadata.id }

  public init(
    metadata: EntityMetadata,
    fiscalYearID: EntityID,
    code: String,
    name: String,
    category: String,
    acquisitionDate: Date,
    serviceDate: Date,
    acquisitionCost: Money,
    usefulLifeYears: Int,
    method: DepreciationMethod,
    decliningRateBasisPoints: Int = 0,
    businessUseBasisPoints: Int = 10_000,
    assetAccountID: EntityID,
    depreciationExpenseAccountID: EntityID,
    accumulatedDepreciationAccountID: EntityID,
    status: FixedAssetStatus = .inService,
    events: [FixedAssetEvent] = [],
    disposalDate: Date? = nil,
    disposalProceeds: Money? = nil
  ) throws {
    guard acquisitionCost.yen > 0 else { throw FixedAssetError.invalidCost }
    guard usefulLifeYears > 0 else { throw FixedAssetError.invalidUsefulLife }
    guard (0...10_000).contains(decliningRateBasisPoints),
      (0...10_000).contains(businessUseBasisPoints)
    else { throw FixedAssetError.invalidRate }
    self.metadata = metadata
    self.fiscalYearID = fiscalYearID
    self.code = code
    self.name = name
    self.category = category
    self.acquisitionDate = acquisitionDate
    self.serviceDate = serviceDate
    self.acquisitionCost = acquisitionCost
    self.usefulLifeYears = usefulLifeYears
    self.method = method
    self.decliningRateBasisPoints = decliningRateBasisPoints
    initialBusinessUseBasisPoints = businessUseBasisPoints
    self.businessUseBasisPoints = businessUseBasisPoints
    self.assetAccountID = assetAccountID
    self.depreciationExpenseAccountID = depreciationExpenseAccountID
    self.accumulatedDepreciationAccountID = accumulatedDepreciationAccountID
    self.status = status
    self.events =
      events.isEmpty
      ? [
        try FixedAssetEvent(occurredOn: acquisitionDate, kind: .acquired),
        try FixedAssetEvent(occurredOn: serviceDate, kind: .placedInService),
      ]
      : events
    self.disposalDate = disposalDate
    self.disposalProceeds = disposalProceeds
  }

  public mutating func changeBusinessUse(to basisPoints: Int, on date: Date, note: String = "")
    throws
  {
    guard status == .inService, (0...10_000).contains(basisPoints) else {
      throw FixedAssetError.invalidEvent
    }
    businessUseBasisPoints = basisPoints
    events.append(
      try FixedAssetEvent(
        occurredOn: date,
        kind: .businessUseChanged,
        businessUseBasisPoints: basisPoints,
        note: note
      ))
    metadata.touch(at: date)
  }

  public mutating func dispose(on date: Date, proceeds: Money, note: String = "") throws {
    guard status == .inService, date >= serviceDate else {
      throw FixedAssetError.disposalBeforeService
    }
    status = .disposed
    disposalDate = date
    disposalProceeds = proceeds
    events.append(
      try FixedAssetEvent(
        occurredOn: date,
        kind: .disposed,
        proceeds: proceeds,
        note: note
      ))
    metadata.touch(at: date)
  }

  public mutating func retire(on date: Date, note: String = "") throws {
    guard status == .inService, date >= serviceDate else { throw FixedAssetError.invalidEvent }
    status = .retired
    disposalDate = date
    events.append(try FixedAssetEvent(occurredOn: date, kind: .retired, note: note))
    metadata.touch(at: date)
  }

  public func depreciationSchedule(through finalYear: Int) throws -> [DepreciationYear] {
    let calendar = Calendar(identifier: .gregorian)
    let startYear = calendar.component(.year, from: serviceDate)
    guard finalYear >= startYear else { return [] }
    var opening = acquisitionCost.yen
    var records: [DepreciationYear] = []
    for year in startYear...finalYear where opening > 1 {
      let months = monthsInService(calendarYear: year, calendar: calendar)
      guard months > 0 else { continue }
      let minimumBookValue: Int64 =
        method == .immediateExpense || method == .pooledThreeYear ? 0 : 1
      let depreciation = min(
        try annualDepreciation(opening: opening, months: months),
        opening - minimumBookValue
      )
      let basisPoints = businessBasisPoints(for: year, calendar: calendar)
      let business = depreciation * Int64(basisPoints) / 10_000
      let closing = opening - depreciation
      records.append(
        DepreciationYear(
          calendarYear: year,
          openingBookValue: Money(yen: opening),
          accountingDepreciation: Money(yen: depreciation),
          businessDepreciation: Money(yen: business),
          closingBookValue: Money(yen: closing),
          monthsInService: months,
          businessUseBasisPoints: basisPoints
        ))
      opening = closing
      if method == .immediateExpense { break }
    }
    return records
  }

  public func depreciationJournal(
    for calendarYear: Int,
    fiscalYear: FiscalYear,
    at date: Date
  ) throws -> JournalEntry {
    guard let year = try depreciationSchedule(through: calendarYear).last,
      year.calendarYear == calendarYear,
      year.businessDepreciation.yen > 0
    else { throw FixedAssetError.invalidEvent }
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: date,
      description: "減価償却 \(code) \(name)",
      kind: .closing,
      lines: [
        try JournalLine(
          accountID: depreciationExpenseAccountID,
          side: .debit,
          amount: year.businessDepreciation,
          memo: "固定資産:\(id.uuidString.lowercased())"
        ),
        try JournalLine(
          accountID: accumulatedDepreciationAccountID,
          side: .credit,
          amount: year.businessDepreciation,
          memo: "固定資産:\(id.uuidString.lowercased())"
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }

  public func acquisitionJournal(
    fiscalYear: FiscalYear,
    paymentAccountID: EntityID,
    at date: Date
  ) throws -> JournalEntry {
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: acquisitionDate,
      description: "固定資産取得 \(code) \(name)",
      lines: [
        try JournalLine(
          accountID: assetAccountID,
          side: .debit,
          amount: acquisitionCost,
          memo: "固定資産:\(id.uuidString.lowercased())"
        ),
        try JournalLine(
          accountID: paymentAccountID,
          side: .credit,
          amount: acquisitionCost,
          memo: "固定資産:\(id.uuidString.lowercased())"
        ),
      ]
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }

  public func disposalJournal(
    fiscalYear: FiscalYear,
    cashAccountID: EntityID,
    gainAccountID: EntityID,
    lossAccountID: EntityID,
    at date: Date
  ) throws -> JournalEntry {
    guard status == .disposed || status == .retired, let disposalDate else {
      throw FixedAssetError.invalidEvent
    }
    let calendarYear = Calendar(identifier: .gregorian).component(.year, from: disposalDate)
    let closingBookValue =
      try depreciationSchedule(through: calendarYear).last?.closingBookValue ?? acquisitionCost
    let accumulated = acquisitionCost.yen - closingBookValue.yen
    let proceeds = disposalProceeds?.yen ?? 0
    var lines: [JournalLine] = []
    if proceeds > 0 {
      lines.append(
        try JournalLine(
          accountID: cashAccountID,
          side: .debit,
          amount: Money(yen: proceeds)
        ))
    }
    if accumulated > 0 {
      lines.append(
        try JournalLine(
          accountID: accumulatedDepreciationAccountID,
          side: .debit,
          amount: Money(yen: accumulated)
        ))
    }
    lines.append(
      try JournalLine(accountID: assetAccountID, side: .credit, amount: acquisitionCost))
    let debitTotal = proceeds + accumulated
    if debitTotal < acquisitionCost.yen {
      lines.append(
        try JournalLine(
          accountID: lossAccountID,
          side: .debit,
          amount: Money(yen: acquisitionCost.yen - debitTotal)
        ))
    } else if debitTotal > acquisitionCost.yen {
      lines.append(
        try JournalLine(
          accountID: gainAccountID,
          side: .credit,
          amount: Money(yen: debitTotal - acquisitionCost.yen)
        ))
    }
    var entry = JournalEntry(
      metadata: EntityMetadata(createdAt: date),
      fiscalYearID: fiscalYearID,
      transactionDate: disposalDate,
      description: "固定資産\(status == .retired ? "除却" : "売却") \(code) \(name)",
      kind: .closing,
      lines: lines
    )
    try entry.post(for: fiscalYear, at: date)
    return entry
  }

  private func annualDepreciation(opening: Int64, months: Int) throws -> Int64 {
    switch method {
    case .straightLine:
      return acquisitionCost.yen / Int64(usefulLifeYears) * Int64(months) / 12
    case .decliningBalance:
      guard decliningRateBasisPoints > 0 else { throw FixedAssetError.invalidRate }
      return opening * Int64(decliningRateBasisPoints) / 10_000 * Int64(months) / 12
    case .immediateExpense:
      return opening
    case .pooledThreeYear:
      return acquisitionCost.yen / 3 * Int64(months) / 12
    }
  }

  private func monthsInService(calendarYear: Int, calendar: Calendar) -> Int {
    let serviceYear = calendar.component(.year, from: serviceDate)
    let serviceMonth = calendar.component(.month, from: serviceDate)
    var firstMonth = calendarYear == serviceYear ? serviceMonth : 1
    var lastMonth = 12
    if let disposalDate {
      let disposalYear = calendar.component(.year, from: disposalDate)
      if calendarYear > disposalYear { return 0 }
      if calendarYear == disposalYear { lastMonth = calendar.component(.month, from: disposalDate) }
    }
    firstMonth = min(max(firstMonth, 1), 12)
    return max(lastMonth - firstMonth + 1, 0)
  }

  private func businessBasisPoints(for year: Int, calendar: Calendar) -> Int {
    events.filter {
      $0.kind == .businessUseChanged && calendar.component(.year, from: $0.occurredOn) <= year
    }
    .sorted { $0.occurredOn < $1.occurredOn }
    .last?.businessUseBasisPoints ?? initialBusinessUseBasisPoints
  }
}
