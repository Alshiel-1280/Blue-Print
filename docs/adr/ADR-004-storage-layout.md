# ADR-004: 保存場所とファイル構成

- 状態: 採用
- 日付: 2026-07-21
- 対象: NFR-SEC-001、FR-BKP-001〜004

## 判断

既定の正本を `~/Library/Application Support/BluePrint/` に置き、次を分離する。

```text
BluePrint/
  Database/blueprint.sqlite
  Evidence/Originals/<uuid>/<original filename>
  Evidence/Derived/<uuid>/
  Rules/<rule-set-id>/
  Backups/Automatic/
  Backups/Manual/
  Diagnostics/
```

DB は証憑の索引・ハッシュ・関連だけを持ち、原本ファイルを BLOB として埋め込まない。マイグレーション前バックアップは DB と WAL を安全に確定した後に作る。利用者指定領域は security-scoped bookmark で保持する。
