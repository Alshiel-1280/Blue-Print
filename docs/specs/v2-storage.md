# Blue-Print v2 storage specification

## Compatibility boundary

Blue-Print v2 is a new data generation. It keeps the existing bundle identifier,
but its application data root is `Application Support/BluePrint-v2` inside the
App Sandbox container.

- `storageGeneration`: 2
- SQLite schema: 1
- backup family: `blueprint-v2`
- backup version: 1

The v2 application entry point does not open, import, copy, migrate, rename, or
delete the v1 `Application Support/BluePrint` root. A v1 backup is rejected
before password-based key derivation. The v1.1 legacy reader remains isolated
from the v2 restore API.

## Layout

```text
BluePrint-v2/
  storage-generation.json
  Database/
    blueprint-v2.sqlite
  Evidence/
    Originals/
    Derived/
  Rules/
  Jobs/
  Backups/
  Diagnostics/
```

Restore is a staged operation. The encrypted archive is authenticated and
validated in a sibling staging directory. On the next launch the current v2
root is moved to `BluePrint-v2-PreRestore-<UUID>`, and the validated stage is
atomically promoted. The v1 root is never a restore target.

## Database rules

One `V2Database` actor owns the SQLite connection and all transaction
boundaries. Domain use cases depend on aggregate repository protocols rather
than SQL.

Mutable accounting state is stored in normalized tables. JSON is limited to
immutable source material:

- OCR source snapshots
- external import source snapshots
- closing-decision source snapshots

In particular, v2 schema 1 has no `payload_json` column.

The principal aggregates are fiscal years, business profiles, accounts,
journal entries and lines, evidence and OCR candidates, evidence links,
journal templates, rules and recurring schedules, import candidates, matching
candidates, journal candidates,
counterparties and roles, invoices and lines, settlements, closing decisions,
audit events, and persistent jobs.

## Sandbox boundary

The app is sandboxed from its first v2 release. User-selected source and
destination files are accessed only while their security-scoped URL is active.
The only network entitlement is outbound client access, used when the user
explicitly requests an update check. There is no telemetry, background update
check, or automatic binary replacement.
