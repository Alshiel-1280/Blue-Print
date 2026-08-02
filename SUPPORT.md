# Support and patch policy

## Priority

1. Crash, database corruption, evidence loss, backup/restore failure
2. Incorrect amount, tax classification, financial statement or filing output
3. Workflow blocker without data loss
4. Accessibility, performance and display defects

Reports must use anonymized data. Never attach a real receipt, `.xtx`, backup,
passphrase, My Number, account number, name or address to a public issue.

## Tax and filing defects

A notice identifies the affected calendar year, app/rule/form versions, whether
existing calculations are affected and whether the user must regenerate a PDF,
CSV or `.xtx`. A fix does not silently rewrite a filed or locked year.

## v2 compatibility

- v2 does not import, open, copy, or delete v1 data or v1 backups.
- v2 schema changes must be additive, transactional, and covered by isolated sample data tests.
- v2 backups use family `blueprint-v2` version 1 and reject every v1 family.
- Existing annual golden tests must remain unchanged and pass.
- A fix that changes a prior-year result requires an explicit compatibility notice and a new rule revision.
- A staged restore preserves the previous v2 root before switching.
- The v1.1 compatibility reader remains isolated from the v2 application entry point.

The latest stable release and the immediately preceding migration source are in
security support. See [SECURITY.md](SECURITY.md) for private reporting.
