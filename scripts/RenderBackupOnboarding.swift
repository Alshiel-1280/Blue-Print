import AppKit
import SwiftUI

@main
struct RenderBackupOnboarding {
  @MainActor
  static func main() throws {
    let view = BackupOnboardingView(configure: {}, postpone: {})
      .environment(\.colorScheme, .light)
      .background(Color.white)
    let hostingView = NSHostingView(rootView: view)
    let size = hostingView.fittingSize
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()

    guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }

    let output = CommandLine.arguments.dropFirst().first ?? "/tmp/backup-onboarding.png"
    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
  }
}
