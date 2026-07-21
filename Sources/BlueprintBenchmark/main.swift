import BlueprintPerformance
import Foundation

let arguments = CommandLine.arguments
let outputURL = URL(
  fileURLWithPath: arguments.count > 1 ? arguments[1] : ".build/performance",
  isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
let databaseURL = outputURL.appendingPathComponent("blueprint-performance.sqlite")
if !fileManager.fileExists(atPath: databaseURL.path) {
  try PerformanceBenchmark.createFixture(at: databaseURL)
}
let report = try PerformanceBenchmark.run(databaseURL: databaseURL)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601
let reportURL = outputURL.appendingPathComponent("performance-report.json")
try encoder.encode(report).write(to: reportURL, options: .atomic)
print(reportURL.path)
if !report.passed { exit(1) }
