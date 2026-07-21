import Foundation

public struct StorageLayout: Equatable, Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public var databaseDirectory: URL { root.appendingPathComponent("Database", isDirectory: true) }
  public var databaseURL: URL { databaseDirectory.appendingPathComponent("blueprint.sqlite") }
  public var evidenceOriginalsDirectory: URL {
    root.appendingPathComponent("Evidence/Originals", isDirectory: true)
  }
  public var evidenceDerivedDirectory: URL {
    root.appendingPathComponent("Evidence/Derived", isDirectory: true)
  }
  public var rulesDirectory: URL { root.appendingPathComponent("Rules", isDirectory: true) }
  public var automaticBackupDirectory: URL {
    root.appendingPathComponent("Backups/Automatic", isDirectory: true)
  }
  public var manualBackupDirectory: URL {
    root.appendingPathComponent("Backups/Manual", isDirectory: true)
  }
  public var diagnosticsDirectory: URL {
    root.appendingPathComponent("Diagnostics", isDirectory: true)
  }

  public static func applicationSupport(fileManager: FileManager = .default) throws -> StorageLayout
  {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return StorageLayout(root: base.appendingPathComponent("BluePrint", isDirectory: true))
  }

  public func createDirectories(fileManager: FileManager = .default) throws {
    for directory in [
      databaseDirectory,
      evidenceOriginalsDirectory,
      evidenceDerivedDirectory,
      rulesDirectory,
      automaticBackupDirectory,
      manualBackupDirectory,
      diagnosticsDirectory,
    ] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  public func applyPendingRestoreIfNeeded(fileManager: FileManager = .default) throws {
    let marker = root.appendingPathComponent("restore-on-next-launch")
    let pending = root.appendingPathComponent("RestorePending", isDirectory: true)
    guard fileManager.fileExists(atPath: marker.path),
      fileManager.fileExists(atPath: pending.appendingPathComponent("Database").path)
    else { return }

    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let rollback = root.appendingPathComponent(
      "Backups/RestoreRollback/\(timestamp)", isDirectory: true)
    try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
    let names = ["Database", "Evidence"]
    for name in names {
      let current = root.appendingPathComponent(name, isDirectory: true)
      if fileManager.fileExists(atPath: current.path) {
        try fileManager.copyItem(at: current, to: rollback.appendingPathComponent(name))
      }
    }
    do {
      for name in names {
        let current = root.appendingPathComponent(name, isDirectory: true)
        let replacement = pending.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: current.path) { try fileManager.removeItem(at: current) }
        if fileManager.fileExists(atPath: replacement.path) {
          try fileManager.moveItem(at: replacement, to: current)
        }
      }
      try fileManager.removeItem(at: pending)
      try fileManager.removeItem(at: marker)
    } catch {
      for name in names {
        let current = root.appendingPathComponent(name, isDirectory: true)
        let saved = rollback.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: current.path) { try? fileManager.removeItem(at: current) }
        if fileManager.fileExists(atPath: saved.path) {
          try? fileManager.copyItem(at: saved, to: current)
        }
      }
      throw error
    }
  }
}
