import BlueprintTransfer
import CryptoKit
import Foundation

public enum V2RestoreCoordinatorError: Error, Equatable, Sendable {
  case restoreAlreadyStaged
  case invalidStage
}

public struct V2RestoreCoordinator: @unchecked Sendable {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func stage(
    payload: V2BackupPayload,
    for layout: V2StorageLayout
  ) throws {
    let markerURL = pendingMarkerURL(for: layout)
    guard !fileManager.fileExists(atPath: markerURL.path) else {
      throw V2RestoreCoordinatorError.restoreAlreadyStaged
    }
    let stage = stageLayout(for: layout)
    guard !fileManager.fileExists(atPath: stage.root.path) else {
      throw V2RestoreCoordinatorError.restoreAlreadyStaged
    }
    try V2BackupService(fileManager: fileManager).restore(payload, to: stage)
    let stagedDatabase = try Data(contentsOf: stage.databaseURL)
    guard Self.sha256(stagedDatabase) == payload.databaseSHA256 else {
      throw V2RestoreCoordinatorError.invalidStage
    }
    let marker = PendingV2Restore(
      storageGeneration: 2,
      stagePath: stage.root.path,
      databaseSHA256: payload.databaseSHA256,
      createdAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(marker).write(to: markerURL, options: .atomic)
  }

  @discardableResult
  public func applyPendingRestoreIfNeeded(
    to layout: V2StorageLayout
  ) throws -> URL? {
    let markerURL = pendingMarkerURL(for: layout)
    guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let marker = try decoder.decode(
      PendingV2Restore.self,
      from: Data(contentsOf: markerURL)
    )
    guard marker.storageGeneration == 2 else {
      throw V2RestoreCoordinatorError.invalidStage
    }
    let expectedStage = stageLayout(for: layout).root.standardizedFileURL
    let markerStage = URL(fileURLWithPath: marker.stagePath).standardizedFileURL
    guard markerStage == expectedStage else {
      throw V2RestoreCoordinatorError.invalidStage
    }
    let stagedDatabase =
      markerStage
      .appendingPathComponent("Database/blueprint-v2.sqlite")
    guard fileManager.fileExists(atPath: stagedDatabase.path),
      Self.sha256(try Data(contentsOf: stagedDatabase)) == marker.databaseSHA256
    else {
      throw V2RestoreCoordinatorError.invalidStage
    }

    let parent = layout.root.deletingLastPathComponent()
    let preserved = parent.appendingPathComponent(
      "BluePrint-v2-PreRestore-\(UUID().uuidString)",
      isDirectory: true
    )
    if fileManager.fileExists(atPath: layout.root.path) {
      try fileManager.moveItem(at: layout.root, to: preserved)
    }
    do {
      try fileManager.moveItem(at: markerStage, to: layout.root)
      try fileManager.removeItem(at: markerURL)
      return fileManager.fileExists(atPath: preserved.path) ? preserved : nil
    } catch {
      if !fileManager.fileExists(atPath: layout.root.path),
        fileManager.fileExists(atPath: preserved.path)
      {
        try? fileManager.moveItem(at: preserved, to: layout.root)
      }
      throw error
    }
  }

  private func stageLayout(for layout: V2StorageLayout) -> V2StorageLayout {
    V2StorageLayout(
      root: layout.root.deletingLastPathComponent()
        .appendingPathComponent("BluePrint-v2-RestoreStage", isDirectory: true)
    )
  }

  private func pendingMarkerURL(for layout: V2StorageLayout) -> URL {
    layout.root.deletingLastPathComponent()
      .appendingPathComponent(".blueprint-v2-pending-restore.json")
  }

  private static func sha256(_ data: Data) -> String {
    importCryptoSHA256(data)
  }
}

private struct PendingV2Restore: Codable {
  let storageGeneration: Int
  let stagePath: String
  let databaseSHA256: String
  let createdAt: Date
}

private func importCryptoSHA256(_ data: Data) -> String {
  // Kept outside the coordinator to make the validation step easy to audit.
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
