# Third-party notices

Blue-Print 0.9.0 does not link third-party package-manager dependencies.

The application uses Apple platform frameworks (SwiftUI, AppKit, PDFKit, Vision,
CryptoKit, Security, UniformTypeIdentifiers and ImageIO) and the SQLite library
provided by macOS. Their use is governed by the Apple developer agreements and
the licenses shipped with macOS/Xcode; they are not redistributed as source in
this repository.

The GitHub Actions workflow uses `actions/checkout@v4` only as CI infrastructure
and it is not included in the application binary.

Last reviewed: 2026-07-21.
