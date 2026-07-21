# Architecture Decision Records

ADR は一度採用した判断を削除せず、変更時は後続 ADR で置き換えます。各 ADR は v0.1 の実装境界と、将来バージョンで再検討する条件を記録します。

| ADR | 判断 |
| --- | --- |
| [ADR-001](./ADR-001-license.md) | Apache License 2.0 |
| [ADR-002](./ADR-002-platform-toolchain.md) | macOS 14+、Apple Silicon、Swift 6 |
| [ADR-003](./ADR-003-sqlite.md) | system SQLite と薄い明示的アクセス層 |
| [ADR-004](./ADR-004-storage-layout.md) | Application Support 内で DB・証憑・バックアップを分離 |
| [ADR-005](./ADR-005-money-tax-rounding.md) | 整数円と明示的端数処理 |
| [ADR-006](./ADR-006-audit-corrections.md) | 追記専用監査と反対・訂正リンク |
| [ADR-007](./ADR-007-rule-distribution.md) | 年度ルールは不変・署名付き配布 |
| [ADR-008](./ADR-008-distribution.md) | Developer ID 署名・公証、更新通知のみ |
| [ADR-009](./ADR-009-encryption-boundaries.md) | ローカル保護と暗号化バックアップを分離 |
| [ADR-010](./ADR-010-capture-protocol.md) | Mac 正本、冪等な暗号化転送 |
