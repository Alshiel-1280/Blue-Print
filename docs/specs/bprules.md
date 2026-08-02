# Signed `.bprules` packages

## Package format

An official annual rule package is a directory whose name ends in `.bprules`.
It contains exactly the signed inputs needed by the verifier:

```text
2026.bprules/
  manifest.json
  payload.json
  signature.ed25519
```

`manifest.json` identifies the schema, rule year, immutable revision, signing
key, supported scopes, payload SHA-256, sources, and verification date.
`payload.json` contains the annual bookkeeping, consumption-tax, closing,
income-tax-form, and XTX rule values that are enabled by the manifest.
`signature.ed25519` is an Ed25519 signature over the canonical signing input.

## Verification

The app verifies, before installation or use:

1. the manifest schema and target year;
2. a known embedded public-key identifier;
3. the SHA-256 digest of `payload.json`;
4. the Ed25519 signature;
5. monotonic revision for the same year; and
6. consistency between declared scopes and decoded payload.

Missing signatures, unknown keys, byte changes, old revisions, and unsupported
years are rejected. A failed candidate never replaces an installed package.

The release private key is not stored in this repository. The release tool
reads it from the macOS Keychain service
`com.ryo1280.blueprint.rule-signing`, account
`release-ed25519-v1`, or from an explicitly configured CI secret.

## Shipped support

The 2025 package is the golden compatibility package and exposes all scopes.
Its accounting, closing, form, and XTX results must remain byte-for-byte
compatible with the retained golden fixtures.

The 2026 package exposes bookkeeping, consumption tax, and closing only.
Income-tax forms and XTX remain unavailable until the final National Tax
Agency forms and e-Tax schema are published and all real-data acceptance gates
are satisfied.

Invoice transitional deductions are selected with independent inputs for
transaction date, taxable period, supplier registration, tax rate, and
applicable purchase cap. Registration state is never encoded into a tax-rate
value.

## Release operation

Use the repository tool to bootstrap or sign packages:

```sh
swift run blueprint-rule-tool bootstrap-and-sign \
  Sources/BlueprintTax/Resources/RulePackages
```

Signing is a release operation. Review payload and sources before signing, and
never commit a private key or an exported Keychain item.
