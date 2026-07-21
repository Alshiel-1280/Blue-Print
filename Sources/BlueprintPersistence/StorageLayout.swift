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
}
