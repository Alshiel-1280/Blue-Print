import Foundation

public enum MoneyError: Error, Equatable, Sendable {
  case overflow
  case invalidDivisor
}

public struct Money: Codable, Equatable, Hashable, Comparable, Sendable {
  public let yen: Int64

  public init(yen: Int64) {
    self.yen = yen
  }

  public static let zero = Money(yen: 0)

  public static func < (lhs: Money, rhs: Money) -> Bool {
    lhs.yen < rhs.yen
  }

  public func adding(_ other: Money) throws -> Money {
    let result = yen.addingReportingOverflow(other.yen)
    guard !result.overflow else { throw MoneyError.overflow }
    return Money(yen: result.partialValue)
  }

  public func subtracting(_ other: Money) throws -> Money {
    let result = yen.subtractingReportingOverflow(other.yen)
    guard !result.overflow else { throw MoneyError.overflow }
    return Money(yen: result.partialValue)
  }

  public func multiplied(by multiplier: Int64) throws -> Money {
    let result = yen.multipliedReportingOverflow(by: multiplier)
    guard !result.overflow else { throw MoneyError.overflow }
    return Money(yen: result.partialValue)
  }
}

public enum RoundingRule: String, Codable, CaseIterable, Sendable {
  case down
  case up
  case nearest

  public func apply(_ value: Decimal) -> Int64 {
    var source = value
    var rounded = Decimal()
    let mode: Decimal.RoundingMode
    switch self {
    case .down: mode = value.sign == .minus ? .up : .down
    case .up: mode = value.sign == .minus ? .down : .up
    case .nearest: mode = .plain
    }
    NSDecimalRound(&rounded, &source, 0, mode)
    return NSDecimalNumber(decimal: rounded).int64Value
  }
}

public enum RoundingUnit: String, Codable, CaseIterable, Sendable {
  case line
  case invoice
  case voucher
}

public enum TaxRate: String, Codable, CaseIterable, Sendable {
  case standard10
  case reduced8
  case exempt
  case outOfScope

  public var basisPoints: Int? {
    switch self {
    case .standard10: 1_000
    case .reduced8: 800
    case .exempt, .outOfScope: nil
    }
  }
}

public enum InvoiceRegistrationStatus: String, Codable, CaseIterable, Sendable {
  case qualified
  case exemptOrUnregistered
  case unknown
}

public enum InvoiceStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case issued
  case partiallyPaid
  case paid
  case cancelled
  case overdue
  case corrected
  case refunded
}
