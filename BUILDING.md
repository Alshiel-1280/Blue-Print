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
export BLUEPRINT_EXPECTED_VERSION='1.0.0'
./scripts/release-preflight.sh
./scripts/release-app.sh .build/release-artifacts
```

The preflight requires a clean worktree, matching application versions, an
available signing identity and a working Notary Service Keychain profile. The
release script repeats the preflight, builds the official origin, enables the
hardened runtime, verifies the signature, submits to Apple Notary Service,
staples the ticket, runs a local Gatekeeper assessment and emits an arm64 zip
plus SHA-256 file. Credentials are never stored in this repository.

`BLUEPRINT_CODESIGN_IDENTITY` may be the full certificate name or its SHA-1
identity hash from `security find-identity -v -p codesigning`. Using the hash
removes ambiguity when certificates with the same display name are present.

## Verification

```sh
codesign --verify --deep --strict --verbose=2 BluePrint.app
spctl --assess --type execute --verbose=2 BluePrint.app
xcrun stapler validate BluePrint.app
shasum -a 256 -c BluePrint-macOS-arm64.zip.sha256
```

## Data and rule compatibility

Application, DB schema, portable data format, tax rules and form rules have
independent versions in `BlueprintVersions`. A patch release must not introduce
a destructive schema change. See [new tax year](docs/maintenance/new-tax-year.md)
for the additive annual update process.
