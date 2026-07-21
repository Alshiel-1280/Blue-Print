import Foundation

public enum CanonicalAuthority: String, Codable, Sendable {
  case mac
}

public enum CaptureDeviceKind: String, Codable, Sendable {
  case mac
  case iPhone
  case scanner
  case importedFile
}

public enum CaptureTransferState: String, Codable, Sendable {
  case local
  case queued
  case transferring
  case acknowledgedByMac
  case failed
}

public struct CaptureSourceMetadata: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let documentID: UUID
  public let originalSHA256: String
  public let deviceID: String
  public let deviceKind: CaptureDeviceKind
  public let capturedAt: Date
  public let mimeType: String
  public let byteCount: Int64
  public var transferState: CaptureTransferState
  public let protocolVersion: Int
  public let canonicalAuthority: CanonicalAuthority

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    originalSHA256: String,
    deviceID: String,
    deviceKind: CaptureDeviceKind,
    capturedAt: Date,
    mimeType: String,
    byteCount: Int64,
    transferState: CaptureTransferState,
    protocolVersion: Int = 1,
    canonicalAuthority: CanonicalAuthority = .mac
  ) {
    self.id = id
    self.documentID = documentID
    self.originalSHA256 = originalSHA256
    self.deviceID = deviceID
    self.deviceKind = deviceKind
    self.capturedAt = capturedAt
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.transferState = transferState
    self.protocolVersion = protocolVersion
    self.canonicalAuthority = canonicalAuthority
  }

  public var idempotencyKey: String {
    "\(documentID.uuidString.lowercased()):\(originalSHA256.lowercased())"
  }
}
