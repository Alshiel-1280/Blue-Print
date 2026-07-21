# ADR-003: SQLite アクセス

- 状態: 採用
- 日付: 2026-07-21
- 対象: NFR-REL-001、NFR-MNT-001、NFR-CMP-003〜004

## 判断

macOS 標準の SQLite 3 を `CSQLite` system library target から利用し、プリペアドステートメント、型付きバインド、明示的トランザクションを提供する薄い自前層を置く。v0.1 は外部 DB 依存を追加しない。

ドメイン層はリポジトリ protocol のみを持ち、SQLite 実装は `BlueprintPersistence` に閉じ込める。UI から SQL を実行しない。

## 理由

会計データの移行と失敗時の挙動を明示的にテストでき、依存更新や ORM の暗黙挙動を減らせる。将来 GRDB 等へ移行する場合も protocol と移行テストを維持する。
