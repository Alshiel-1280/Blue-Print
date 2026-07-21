import XCTest

@testable import BlueprintAudit

final class AuditEventTests: XCTestCase {
  func testAppendAndTargetFilteringPreserveOrder() throws {
    let store = InMemoryAuditEventStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let first = AuditEvent(
      occurredAt: base,
      actorKind: .localUser,
      action: .created,
      targetType: "BusinessProfile",
      targetID: "profile-1"
    )
    let second = AuditEvent(
      occurredAt: base.addingTimeInterval(1),
      actorKind: .localUser,
      action: .updated,
      targetType: "BusinessProfile",
      targetID: "profile-1"
    )
    let other = AuditEvent(
      occurredAt: base.addingTimeInterval(2),
      actorKind: .system,
      action: .created,
      targetType: "Account",
      targetID: "account-1"
    )

    try store.append(first)
    try store.append(second)
    try store.append(other)

    XCTAssertEqual(try store.fetchAll(), [first, second, other])
    XCTAssertEqual(
      try store.fetch(targetType: "BusinessProfile", targetID: "profile-1"),
      [first, second]
    )
  }
}
