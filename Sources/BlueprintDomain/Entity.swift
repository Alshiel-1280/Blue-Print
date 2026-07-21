import Foundation

public typealias EntityID = UUID

public struct EntityMetadata: Codable, Equatable, Hashable, Sendable {
  public let id: EntityID
  public let createdAt: Date
  public var updatedAt: Date

  public init(id: EntityID = UUID(), createdAt: Date, updatedAt: Date? = nil) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  public mutating func touch(at date: Date) {
    updatedAt = date
  }
}

public protocol BlueprintClock: Sendable {
  func now() -> Date
}

public struct SystemClock: BlueprintClock {
  public init() {}

  public func now() -> Date { Date() }
}

public struct FixedClock: BlueprintClock {
  private let value: Date

  public init(_ value: Date) {
    self.value = value
  }

  public func now() -> Date { value }
}
