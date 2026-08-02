# Building Blue-Print

## Supported toolchain

- Apple Silicon Mac
- macOS 14 or later
- Xcode 26.2 / Swift 6.2
- macOS system SQLite

## Build and test

```sh
swift format lint --recursive --strict Sources Tests Package.swift
swift test
swift build -c release
./scripts/package-app.sh release .build/app self
```

The final argument is the build origin. `self` produces a UI label of
`self-built release`. Only the release script may pass `official`; that build
uses the `BLUEPRINT_OFFICIAL_BUILD` compilation condition and is then signed and
notarized.

## Official release

Import a Developer ID Application certificate and create an `notarytool`
Keychain profile first. The release operator then runs:

```sh
export BLUEPRINT_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)'
export BLUEPRINT_NOTARY_PROFILE='blueprint-notary'
export BLUEPRINT_EXPECTED_VERSION='2.0.0'
export BLUEPRINT_RELEASE_DOWNLOAD_URL='https://github.com/Alshiel-1280/Blue-Print/releases/download/v2.0.0/BluePrint-v2.0.0-macOS-AppleSilicon.dmg'
./scripts/release-preflight.sh
./scripts/release-app.sh .build/release-artifacts
```

The preflight requires a clean worktree, matching application versions, an
available signing identity and a working Notary Service Keychain profile. The
release script repeats the preflight, builds the official origin, enables the
hardened runtime, verifies the signature, submits to Apple Notary Service,
signs the DMG container, submits the DMG to Apple Notary Service, staples the
ticket, verifies both the DMG and app with Gatekeeper, and emits the Apple
Silicon DMG, SHA-256 file, and Ed25519-signed `update-manifest.json`.
Credentials and the Ed25519 private key are never stored in this repository.

`BLUEPRINT_CODESIGN_IDENTITY` may be the full certificate name or its SHA-1
identity hash from `security find-identity -v -p codesigning`. Using the hash
removes ambiguity when certificates with the same display name are present.

## Verification

```sh
codesign --verify --deep --strict --verbose=2 BluePrint.app
codesign -d --entitlements :- BluePrint.app
codesign --verify --verbose=2 BluePrint-v2.0.0-macOS-AppleSilicon.dmg
xcrun stapler validate BluePrint-v2.0.0-macOS-AppleSilicon.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 \
  BluePrint-v2.0.0-macOS-AppleSilicon.dmg
spctl --assess --type execute --verbose=2 BluePrint.app
shasum -a 256 -c BluePrint-v2.0.0-macOS-AppleSilicon.dmg.sha256
```

## Data and rule compatibility

The v2 app, storage generation, schema, backup family, capture contract, tax
rules and form rules are independently versioned. `BlueprintLegacyVersions`
exists only for the explicit v1 restore reader and retained v1 fixtures. See
[new tax year](docs/maintenance/new-tax-year.md) and
[the `.bprules` specification](docs/specs/bprules.md).
