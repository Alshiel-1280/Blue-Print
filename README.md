# Blue-Print

Blue-Print は、日本の個人事業主が Mac 上で記帳から青色申告の準備までを行うための、ローカルファーストな OSS 会計アプリです。Mac のローカルデータを正本とし、通常の記帳・閲覧・決算は外部通信なしで動作することを目指します。

> [!WARNING]
> このアプリは税務判断や税理士業務を代替しません。対応年度、根拠資料、既知の制限を確認し、申告内容は e-Tax WEB 版等で最終確認してください。

## 現在のマイルストーン

`v0.1` — プロジェクト・データ基盤。事業者、年度、勘定科目、SQLite マイグレーション、監査記録、初回セットアップを実装します。

実装順と完了条件は [plan.md](./plan.md)、要求の基準は [要件定義書.md](./要件定義書.md) を参照してください。

## 必要環境

- macOS 14 Sonoma 以降（最新 macOS と過去2メジャーを対象）
- Apple Silicon
- Xcode 26.2 / Swift 6.2 で検証
- SQLite 3（macOS システムライブラリ）

## ビルドとテスト

```sh
swift build
swift test
swift run BluePrint
```

開発用 `.app` バンドルは次で作成できます。

```sh
./scripts/package-app.sh debug
```

リリース構成は `swift build -c release` で確認できます。Xcode では `Package.swift` を開くと、macOS アプリと共有モジュールを同じワークスペースで扱えます。

## モジュール境界

- `BlueprintDomain`: 会計値、事業者、年度、勘定科目、リポジトリ契約
- `BlueprintAudit`: 追記専用の監査イベント
- `BlueprintPersistence`: SQLite、トランザクション、マイグレーション、リポジトリ実装
- `BlueprintSharedCapture`: 将来の iPhone 撮影連携で共有する証憑メタデータ
- `BlueprintApp`: SwiftUI macOS アプリ

`BlueprintDomain` は永続化実装へ依存しません。UI から SQLite を直接更新せず、リポジトリとユースケースを経由します。

## データ保存

既定では `~/Library/Application Support/BluePrint/` に DB、証憑索引、バックアップを分離して保存します。詳細は [ADR-004](./docs/adr/ADR-004-storage-layout.md) を参照してください。

## ライセンス

Apache License 2.0。詳細は [LICENSE](./LICENSE) を参照してください。依存ライブラリを追加する場合は、ライセンスと脆弱性をリリース前に確認します。

## セキュリティ

脆弱性やデータ破損につながる問題は、公開 Issue へ税務データを添付せず [SECURITY.md](./SECURITY.md) の手順で報告してください。
