import BlueprintBilling
import BlueprintDomain
import Foundation

public struct ReportAccountAmount: Equatable, Sendable, Identifiable {
  public let accountID: EntityID
  public let accountCode: String
  public let accountName: String
  public let amount: Money

  public var id: EntityID { accountID }
}

public struct ProfitAndLossReport: Equatable, Sendable {
  public let period: ClosedRange<Date>
  public let revenue: [ReportAccountAmount]
  public let expenses: [ReportAccountAmount]
  public let totalRevenue: Money
  public let totalExpenses: Money
  public let profit: Money
}

public struct BalanceSheetReport: Equatable, Sendable {
  public let asOf: Date
  public let assets: [ReportAccountAmount]
  public let liabilities: [ReportAccountAmount]
  public let equity: [ReportAccountAmount]
  public let totalAssets: Money
  public let totalLiabilitiesAndEquity: Money
  public let currentProfit: Money

  public var balances: Bool { totalAssets == totalLiabilitiesAndEquity }
}

public enum AgingBucket: String, Codable, CaseIterable, Sendable {
  case current
  case days1To30
  case days31To60
  case days61To90
  case over90
}

public struct AgingAmount: Equatable, Sendable, Identifiable {
  public let counterpartyID: EntityID
  public let counterpartyName: String
  public let bucket: AgingBucket
  public let amount: Money

  public var id: String { "\(counterpartyID.uuidString)|\(bucket.rawValue)" }
}

public enum ClosingReports {
  public static func profitAndLoss(
    entries: [JournalEntry],
    accounts: [Account],
    period: ClosedRange<Date>
  ) throws -> ProfitAndLossReport {
    let selected = entries.filter {
      $0.status.countsInLedger && period.contains($0.transactionDate)
    }
    let revenue = try amounts(
      entries: selected,
      accounts: accounts.filter { $0.category == .revenue },
      creditNormal: true
    )
    let expenses = try amounts(
      entries: selected,
      accounts: accounts.filter { $0.category == .expense },
      creditNormal: false
    )
    let totalRevenue = Money(yen: revenue.reduce(0) { $0 + $1.amount.yen })
    let totalExpenses = Money(yen: expenses.reduce(0) { $0 + $1.amount.yen })
    return ProfitAndLossReport(
      period: period,
      revenue: revenue,
      expenses: expenses,
      totalRevenue: totalRevenue,
      totalExpenses: totalExpenses,
      profit: Money(yen: totalRevenue.yen - totalExpenses.yen)
    )
  }

  public static func balanceSheet(
    entries: [JournalEntry],
    accounts: [Account],
    fiscalYearPeriod: ClosedRange<Date>,
    asOf: Date
  ) throws -> BalanceSheetReport {
    let selected = entries.filter {
      $0.status.countsInLedger && $0.transactionDate <= asOf
    }
    let assets = try amounts(
      entries: selected,
      accounts: accounts.filter { $0.category == .asset },
      creditNormal: false
    )
    let liabilities = try amounts(
      entries: selected,
      accounts: accounts.filter { $0.category == .liability },
      creditNormal: true
    )
    let equity = try amounts(
      entries: selected,
      accounts: accounts.filter { $0.category == .equity },
      creditNormal: true
    )
    let profit = try profitAndLoss(
      entries: entries,
      accounts: accounts,
      period: fiscalYearPeriod.lowerBound...min(asOf, fiscalYearPeriod.upperBound)
    ).profit
    let totalAssets = Money(yen: assets.reduce(0) { $0 + $1.amount.yen })
    let liabilitiesAndEquity =
      liabilities.reduce(0) { $0 + $1.amount.yen }
      + equity.reduce(0) { $0 + $1.amount.yen }
      + profit.yen
    return BalanceSheetReport(
      asOf: asOf,
      assets: assets,
      liabilities: liabilities,
      equity: equity,
      totalAssets: totalAssets,
      totalLiabilitiesAndEquity: Money(yen: liabilitiesAndEquity),
      currentProfit: profit
    )
  }

  public static func receivableAging(
    invoices: [Invoice],
    counterparties: [Counterparty],
    asOf: Date
  ) throws -> [AgingAmount] {
    var values: [String: Int64] = [:]
    for invoice in invoices where invoice.status.isAgingOpen && invoice.issueDate <= asOf {
      let bucket = agingBucket(dueDate: invoice.dueDate, asOf: asOf)
      let key = "\(invoice.counterpartyID.uuidString)|\(bucket.rawValue)"
      values[key, default: 0] += try invoice.outstandingAmount().yen
    }
    return values.compactMap { key, value in
      let parts = key.split(separator: "|")
      guard parts.count == 2,
        let id = UUID(uuidString: String(parts[0])),
        let bucket = AgingBucket(rawValue: String(parts[1]))
      else { return nil }
      return AgingAmount(
        counterpartyID: id,
        counterpartyName: counterparties.first { $0.id == id }?.displayName ?? "取引先未設定",
        bucket: bucket,
        amount: Money(yen: value)
      )
    }.sorted {
      $0.counterpartyName == $1.counterpartyName
        ? $0.bucket.rawValue < $1.bucket.rawValue : $0.counterpartyName < $1.counterpartyName
    }
  }

  public static func payableAging(
    bills: [VendorBill],
    counterparties: [Counterparty],
    asOf: Date
  ) throws -> [AgingAmount] {
    var values: [String: Int64] = [:]
    for bill in bills where bill.status.isAgingOpen && bill.issueDate <= asOf {
      let bucket = agingBucket(dueDate: bill.dueDate, asOf: asOf)
      let key = "\(bill.vendorID.uuidString)|\(bucket.rawValue)"
      values[key, default: 0] += try bill.outstandingAmount().yen
    }
    return values.compactMap { key, value in
      let parts = key.split(separator: "|")
      guard parts.count == 2,
        let id = UUID(uuidString: String(parts[0])),
        let bucket = AgingBucket(rawValue: String(parts[1]))
      else { return nil }
      return AgingAmount(
        counterpartyID: id,
        counterpartyName: counterparties.first { $0.id == id }?.displayName ?? "取引先未設定",
        bucket: bucket,
        amount: Money(yen: value)
      )
    }.sorted {
      $0.counterpartyName == $1.counterpartyName
        ? $0.bucket.rawValue < $1.bucket.rawValue : $0.counterpartyName < $1.counterpartyName
    }
  }

  private static func amounts(
    entries: [JournalEntry],
    accounts: [Account],
    creditNormal: Bool
  ) throws -> [ReportAccountAmount] {
    var result: [ReportAccountAmount] = []
    for account in accounts {
      var signed: Int64 = 0
      for line in entries.flatMap(\.lines) where line.accountID == account.id {
        let normalSide: PostingSide = creditNormal ? .credit : .debit
        signed += line.side == normalSide ? line.amount.yen : -line.amount.yen
      }
      guard signed != 0 else { continue }
      result.append(
        ReportAccountAmount(
          accountID: account.id,
          accountCode: account.code,
          accountName: account.name,
          amount: Money(yen: signed)
        ))
    }
    return result.sorted { $0.accountCode < $1.accountCode }
  }

  private static func agingBucket(dueDate: Date, asOf: Date) -> AgingBucket {
    guard dueDate < asOf else { return .current }
    let days = max(Calendar.current.dateComponents([.day], from: dueDate, to: asOf).day ?? 0, 1)
    switch days {
    case 1...30: return .days1To30
    case 31...60: return .days31To60
    case 61...90: return .days61To90
    default: return .over90
    }
  }
}

extension InvoiceStatus {
  fileprivate var isAgingOpen: Bool {
    self == .issued || self == .partiallyPaid || self == .overdue
  }
}

extension VendorBillStatus {
  fileprivate var isAgingOpen: Bool { self == .confirmed || self == .partiallyPaid }
}
