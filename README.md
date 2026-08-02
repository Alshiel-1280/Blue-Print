# Blue-Print

Blue-Print は、日本の個人事業主が Mac 上で記帳から青色申告の準備までを行うための、ローカルファーストな OSS 会計アプリです。Mac のローカルデータを正本とし、通常の記帳・閲覧・決算は外部通信なしで動作することを目指します。

> [!WARNING]
> このアプリは税務判断や税理士業務を代替しません。対応年度、根拠資料、既知の制限を確認し、申告内容は e-Tax WEB 版等で最終確認してください。

## 現在のマイルストーン

`v2.0.0` — v1と互換性を持たない新しい保存世代です。作業中心UI、正規化SQLite、
署名付き年度ルール、永続ジョブ、診断・修復プレビュー、Argon2id暗号化バックアップ、
App Sandboxを提供します。v1データは検出・読込・コピー・削除しません。

2026年は記帳・消費税・決算に対応します。2026年の申告書とXTXは、最終様式、
e-Tax仕様、e-Tax WEB実読込、PDF全項目照合が完了するまで無効です。

実装順と完了条件は [plan.md](./plan.md)、v2の保存境界は
[v2 storage specification](./docs/specs/v2-storage.md)、制限は
[v2.0.0リリースノート](./docs/release/v2.0.0.md) を参照してください。

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

詳細な自己ビルド、公式署名・公証、検証手順は [BUILDING.md](./BUILDING.md) にあります。
安定版の問題優先度と互換性規則は [SUPPORT.md](./SUPPORT.md) を参照してください。

## モジュール境界

- `BlueprintDomain`: 会計値、事業者、年度、勘定科目、リポジトリ契約
- `BlueprintAudit`: 追記専用の監査イベント
- `BlueprintPersistence`: SQLite、トランザクション、マイグレーション、リポジトリ実装
- `BlueprintSharedCapture`: 将来の iPhone 撮影連携で共有する証憑メタデータ
- `BlueprintDocuments` / `BlueprintImports`: 証憑原本、オンデバイスOCR、CSV取込
- `BlueprintBilling` / `BlueprintClosing`: 請求・支払・決算・レポート
- `BlueprintFiling` / `BlueprintTax` / `BlueprintETax`: 年度集約、税務ルール、XTX
- `BlueprintTransfer`: 弥生移行と持ち出し形式
- `BlueprintPerformance`: 10万仕訳明細・2万証憑の再現可能な性能基準
- `BlueprintApp`: SwiftUI macOS アプリ

`BlueprintDomain` は永続化実装へ依存しません。UI から SQLite を直接更新せず、リポジトリとユースケースを経由します。

## データ保存

v2はSandboxコンテナ内の `Application Support/BluePrint-v2/` にDB、証憑、
ルール、ジョブ、バックアップを分離して保存します。v1の
`Application Support/BluePrint/` は変更しません。詳細は
[ADR-004](./docs/adr/ADR-004-storage-layout.md) を参照してください。

## ライセンス

Apache License 2.0。詳細は [LICENSE](./LICENSE)、同梱するArgon2公式C実装を含む
確認結果は [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) を参照してください。

## セキュリティ

脆弱性やデータ破損につながる問題は、公開 Issue へ税務データを添付せず [SECURITY.md](./SECURITY.md) の手順で報告してください。
