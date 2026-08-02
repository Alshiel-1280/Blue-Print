# Third-party notices

Blue-Print does not link third-party package-manager dependencies.

## Argon2 reference implementation

Blue-Print vendors the Argon2 reference C implementation, release `20190702`,
commit `62358ba2123abd17fccf2a108a301d4b52c01a7c`, for Argon2id backup key
derivation.

- Upstream: <https://github.com/P-H-C/phc-winner-argon2>
- Copyright 2015 Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson,
  and Samuel Neves
- License used by Blue-Print: Apache License 2.0
- Full upstream license text: `Vendor/argon2/LICENSE`

The application uses Apple platform frameworks (SwiftUI, AppKit, PDFKit, Vision,
CryptoKit, Security, UniformTypeIdentifiers and ImageIO) and the SQLite library
provided by macOS. Their use is governed by the Apple developer agreements and
the licenses shipped with macOS/Xcode; they are not redistributed as source in
this repository.

The GitHub Actions workflow uses `actions/checkout@v4` only as CI infrastructure
and it is not included in the application binary.

Last reviewed: 2026-07-29.
