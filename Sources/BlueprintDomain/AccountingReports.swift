import Foundation

public struct AccountBalance: Equatable, Sendable, Identifiable {
  public let accountID: EntityID
  public let debit: Money
  public let credit: Money

  public var id: EntityID { accountID }
  public var net: Money { Money(yen: debit.yen - credit.yen) }
}

public struct TrialBalance: Equatable, Sendable {
  public let accounts: [AccountBalance]
  public let totalDebits: Money
  public let totalCredits: Money

  public var isBalanced: Bool { totalDebits == totalCredits }
}

public struct LedgerItem: Equatable, Sendable, Identifiable {
  public let entryID: EntityID
  public let lineID: EntityID
  public let date: Date
  public let description: String
  public let debit: Money
  public let credit: Money
  public let runningBalance: Money

  public var id: EntityID { lineID }
}

public enum AccountingReports {
  public static func trialBalance(entries: [JournalEntry]) throws -> TrialBalance {
    var values: [EntityID: (debit: Money, credit: Money)] = [:]
    for entry in entries where entry.status.countsInLedger {
      for line in entry.lines {
        var value = values[line.accountID] ?? (.zero, .zero)
        if line.side == .debit {
          value.debit = try value.debit.adding(line.amount)
        } else {
          value.credit = try value.credit.adding(line.amount)
        }
        values[line.accountID] = value
      }
    }
    let accounts = values.map { id, value in
      AccountBalance(accountID: id, debit: value.debit, credit: value.credit)
    }.sorted { $0.accountID.uuidString < $1.accountID.uuidString }
    let debit = try accounts.reduce(Money.zero) { try $0.adding($1.debit) }
    let credit = try accounts.reduce(Money.zero) { try $0.adding($1.credit) }
    return TrialBalance(accounts: accounts, totalDebits: debit, totalCredits: credit)
  }

  public static func ledger(accountID: EntityID, entries: [JournalEntry]) throws -> [LedgerItem] {
    var running = Money.zero
    var result: [LedgerItem] = []
    for entry in entries.filter({ $0.status.countsInLedger }).sorted(by: entrySort) {
      for line in entry.lines where line.accountID == accountID {
        if line.side == .debit {
          running = try running.adding(line.amount)
        } else {
          running = try running.subtracting(line.amount)
        }
        result.append(
          LedgerItem(
            entryID: entry.id,
            lineID: line.id,
            date: entry.transactionDate,
            description: entry.description,
            debit: line.side == .debit ? line.amount : .zero,
            credit: line.side == .credit ? line.amount : .zero,
            runningBalance: running
          )
        )
      }
    }
    return result
  }

  private static func entrySort(_ lhs: JournalEntry, _ rhs: JournalEntry) -> Bool {
    if lhs.transactionDate != rhs.transactionDate {
      return lhs.transactionDate < rhs.transactionDate
    }
    return lhs.metadata.createdAt < rhs.metadata.createdAt
  }
}
