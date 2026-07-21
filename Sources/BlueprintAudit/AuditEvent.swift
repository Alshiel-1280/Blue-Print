import BlueprintDomain
import Foundation

public enum AuditActorKind: String, Codable, CaseIterable, Sendable {
  case localUser
  case system
  case importer
}

public enum AuditAction: String, Codable, CaseIterable, Sendable {
  case created
  case updated
  case deactivated
  case cancelled
  case corrected
  case fiscalYearLocked
  case fiscalYearReopened
  case migrationStarted
  case migrationCompleted
}

public struct AuditEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: EntityID
  public let occurredAt: Date
  public let actorKind: AuditActorKind
  public let action: AuditAction
  public let targetType: String
  public let targetID: String
  public let reason: String?
  public let relatedEventID: EntityID?

  public init(
    id: EntityID = UUID(),
    occurredAt: Date,
    actorKind: AuditActorKind,
    action: AuditAction,
    targetType: String,
    targetID: String,
    reason: String? = nil,
    relatedEventID: EntityID? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.actorKind = actorKind
    self.action = action
    self.targetType = targetType
    self.targetID = targetID
    self.reason = reason
    self.relatedEventID = relatedEventID
  }
}

public protocol AuditEventRepository: Sendable {
  func append(_ event: AuditEvent) throws
  func fetchAll() throws -> [AuditEvent]
  func fetch(targetType: String, targetID: String) throws -> [AuditEvent]
}

public final class InMemoryAuditEventStore: AuditEventRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [AuditEvent] = []

  public init() {}

  public func append(_ event: AuditEvent) throws {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }

  public func fetchAll() throws -> [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  public func fetch(targetType: String, targetID: String) throws -> [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { $0.targetType == targetType && $0.targetID == targetID }
  }
}
