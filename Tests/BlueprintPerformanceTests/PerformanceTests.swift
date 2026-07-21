import BlueprintPerformance
import XCTest

final class PerformanceTests: XCTestCase {
  func testMetricUsesInclusiveTarget() {
    XCTAssertTrue(PerformanceMetric(name: "exact", seconds: 1, targetSeconds: 1).passed)
    XCTAssertFalse(PerformanceMetric(name: "slow", seconds: 1.01, targetSeconds: 1).passed)
  }

  func testReportRequiresEveryMetricToPass() {
    let report = PerformanceReport(
      generatedAt: Date(), appVersion: "test", journalEntries: 50_000,
      journalLines: 100_000, evidenceRecords: 20_000, peakResidentBytes: 1,
      metrics: [PerformanceMetric(name: "search", seconds: 0.1, targetSeconds: 1)])
    XCTAssertTrue(report.passed)
  }
}
