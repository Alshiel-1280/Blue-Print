import BlueprintDomain
import Foundation

public enum V2StorageError: Error, Equatable, Sendable {
  case invalidGeneration(found: Int)
}

public struct V2StorageLayout: Equatable, Sendable {
  public static let directoryName = "BluePrint-v2"

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public init(applicationSupportBase: URL) {
    root = applicationSupportBase.appendingPathComponent(Self.directoryName, isDirectory: true)
  }

  public var databaseDirectory: URL {
    root.appendingPathComponent("Database", isDirectory: true)
  }
  public var databaseURL: URL {
    databaseDirectory.appendingPathComponent("blueprint-v2.sqlite")
  }
  public var evidenceOriginalsDirectory: URL {
    root.appendingPathComponent("Evidence/Originals", isDirectory: true)
  }
  public var evidenceDerivedDirectory: URL {
    root.appendingPathComponent("Evidence/Derived", isDirectory: true)
  }
  public var rulesDirectory: URL {
    root.appendingPathComponent("Rules", isDirectory: true)
  }
  public var jobsDirectory: URL {
    root.appendingPathComponent("Jobs", isDirectory: true)
  }
  public var backupsDirectory: URL {
    root.appendingPathComponent("Backups", isDirectory: true)
  }
  public var diagnosticsDirectory: URL {
    root.appendingPathComponent("Diagnostics", isDirectory: true)
  }
  public var generationMarkerURL: URL {
    root.appendingPathComponent("storage-generation.json")
  }

  public static func applicationSupport(
    fileManager: FileManager = .default
  ) throws -> V2StorageLayout {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return V2StorageLayout(applicationSupportBase: base)
  }

  public func prepare(fileManager: FileManager = .default) throws {
    for directory in [
      databaseDirectory,
      evidenceOriginalsDirectory,
      evidenceDerivedDirectory,
      rulesDirectory,
      jobsDirectory,
      backupsDirectory,
      diagnosticsDirectory,
    ] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    if fileManager.fileExists(atPath: generationMarkerURL.path) {
      let marker = try JSONDecoder().decode(
        StorageGenerationMarker.self,
        from: Data(contentsOf: generationMarkerURL)
      )
      guard marker.storageGeneration == BlueprintStorageGeneration.v2.rawValue else {
        throw V2StorageError.invalidGeneration(found: marker.storageGeneration)
      }
      return
    }
    let marker = StorageGenerationMarker(
      storageGeneration: BlueprintStorageGeneration.v2.rawValue,
      databaseSchema: 1,
      backupFamily: "blueprint-v2",
      backupVersion: 1
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(marker).write(to: generationMarkerURL, options: .atomic)
  }
}

private struct StorageGenerationMarker: Codable {
  let storageGeneration: Int
  let databaseSchema: Int
  let backupFamily: String
  let backupVersion: Int
}
