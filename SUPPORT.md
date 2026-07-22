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

## v1.0.x compatibility

- Patch releases do not remove a table, column, data-format field or supported rule.
- Schema changes must be additive, transactional and covered by migration plus rollback-retention tests.
- Existing annual golden tests must remain unchanged and pass.
- A fix that changes a prior-year result requires an explicit compatibility notice and a new rule revision.
- The previous database is retained before migration; backup restoration remains supported.

The latest stable release and the immediately preceding migration source are in
security support. See [SECURITY.md](SECURITY.md) for private reporting.
