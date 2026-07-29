# v1 release checklist

## Product and data

- [x] 107 automated tests pass
- [x] 100,000 journal-line / 20,000 evidence benchmark passes
- [x] Backup and restore rehearsal matches counts, balances and evidence hashes
- [x] Accessibility and option-2 design QA recorded
- [x] e-Tax WEB 2025 import accepted

## Supply chain

- [x] No third-party Swift package dependency
- [x] License and third-party notices reviewed
- [x] Self-built and official build origins differ
- [x] Notary Service Keychain profile validates with `notarytool history`
- [x] Developer ID signature verified
- [x] Apple notarization and staple verified
- [x] Local Gatekeeper assessment passes
- [x] Gatekeeper assessment passes on a second Mac

## Publication

- [x] Change app version and build number to 1.0.0
- [x] Commit the final release note
- [x] Create annotated `v1.0.0` tag from the verified commit
- [x] Upload notarized arm64 zip and SHA-256 to GitHub Releases
- [x] Confirm source archives and release assets are publicly downloadable
- [x] Verify tag, app version and release title are identical

Do not check an external gate based only on a script or local unit test.
