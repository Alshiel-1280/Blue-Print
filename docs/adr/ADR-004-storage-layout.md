# ADR-004: 保存場所とファイル構成

- 状態: 採用
- 日付: 2026-07-21
- 対象: NFR-SEC-001、FR-BKP-001〜004

## 判断

v2の正本をSandboxコンテナ内の `Application Support/BluePrint-v2/` に置き、
v1の `Application Support/BluePrint/` と完全に分離する。

```text
BluePrint-v2/
  storage-generation.json
  Database/blueprint-v2.sqlite
  Evidence/Originals/<uuid>.<extension>
  Evidence/Derived/
  Rules/<year>.bprules/
  Jobs/
  Backups/
  Diagnostics/
```

`storageGeneration = 2`、DB schema 1、backup family `blueprint-v2` version 1
から開始する。DBは証憑の索引・ハッシュ・関連だけを持ち、原本をBLOB化しない。
v1ルートを検出しても読み書き・コピー・削除しない。利用者選択ファイルは
security-scoped URLの有効期間内だけ読む。
