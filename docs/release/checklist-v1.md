# v1 release checklist

## Product and data

- [x] 104 automated tests pass
- [x] 100,000 journal-line / 20,000 evidence benchmark passes
- [x] Backup and restore rehearsal matches counts, balances and evidence hashes
- [x] Accessibility and option-2 design QA recorded
- [ ] e-Tax WEB 2025 import accepted

## Supply chain

- [x] No third-party Swift package dependency
- [x] License and third-party notices reviewed
- [x] Self-built and official build origins differ
- [ ] Developer ID signature verified
- [ ] Apple notarization and staple verified
- [ ] Gatekeeper assessment passes on a second Mac

## Publication

- [ ] Change app version and build number to 1.0.0
- [ ] Commit the final release note
- [ ] Create annotated `v1.0.0` tag from the verified commit
- [ ] Upload notarized arm64 zip and SHA-256 to GitHub Releases
- [ ] Confirm source archives and release assets are publicly downloadable
- [ ] Verify tag, app version and release title are identical

Do not check an external gate based only on a script or local unit test.
