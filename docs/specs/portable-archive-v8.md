# Blue-Print Portable Archive v8

`blueprint-portable-archive` は、Blue-Print v0.8 で全データを持ち出すための UTF-8 JSON 形式です。

- `manifest`: アプリ・DB・形式の版、全テーブル件数、借貸合計、証憑件数・SHA-256
- `tables`: SQLite の全ユーザーテーブル。各値は `integer`、`real`、`text`、`blobBase64`、`null` のタグ付き値
- `csvTables`: 各テーブルを UTF-8／CRLF のCSVとして表現した文字列
- `evidence`: 証憑原本の相対パス、SHA-256、バイト数、Base64データ
- `databaseSnapshotBase64`: 内容検証用DBを再構成するSQLiteスナップショット

JSON Schema は [portable-archive-v8.schema.json](portable-archive-v8.schema.json) を参照してください。アプリは自身より新しい `formatVersion` または `databaseSchemaVersion` の復元を拒否します。

暗号化バックアップは、このJSON全体を100,000回の反復SHA-256で導出した256-bit鍵とAES-256-GCMで認証付き暗号化します。復号後もマニフェスト、DB整合性、テーブル件数、借貸合計、証憑ハッシュを検証します。
