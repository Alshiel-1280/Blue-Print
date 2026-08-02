# v2 packaged-app visual audit

These captures were taken on 2026-07-29 from a packaged, ad-hoc-signed v2 app
using an isolated App Sandbox container. The audit data used fiscal year 2025
and did not read or modify a v1 storage root.

## Captured states

- [`home.png`](./home.png): work blockers, next action, status metrics, and
  non-truncated utility navigation;
- [`daily.png`](./daily.png): journal entry, evidence/import matching,
  candidates, localized tax and review states, and billing workspace;
- [`books-empty.png`](./books-empty.png): explicit empty ledger state rather
  than an ambiguous loading placeholder;
- [`filing-blocked.png`](./filing-blocked.png): localized annual support matrix,
  filing identity fields, and explicit blockers before XTX generation;
- [`utilities.png`](./utilities.png): jobs, backups, diagnostics, updates, and
  localized audit history.

## Findings applied

- shortened the sidebar utility label to prevent truncation while retaining the
  full page title;
- localized raw enum values for tax, invoice, job, evidence, audit, and rule
  scope states;
- replaced the empty Books table with a clear empty-state message;
- changed the Home filing metric from a binary value to the actual blocker
  count and preserved blocker priority;
- added explicit invoice issue and full-settlement actions to the Daily Work
  billing area.

## Remaining release-operator audit

The external Computer Use accessibility service terminated while traversing
the SwiftUI accessibility hierarchy. BluePrint itself remained running, and
targeted packaged-window captures continued to work. Complete VoiceOver speech
order, focus traversal, the five uncaptured scenarios, failure/resume
interaction, and contrast under active-window rendering must therefore be
checked before the official release.
