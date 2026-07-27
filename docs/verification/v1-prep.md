# v1準備検証記録

実施日: 2026-07-22

## 自動検証

- `plutil -lint`: 成功
- JSON構文検証: 成功
- シェル構文検証: 成功
- `swift test`: 104件成功、失敗0件
- `swift build -c release`: 成功
- `git diff --check`: 成功
- 自己ビルド用アプリバンドル: `PkgInfo`を生成し、バンドル全体をad-hoc署名
- `codesign --verify --deep --strict`: 成功

## 初回バックアップ案内

- `NSHostingView`で実装ビューをオフスクリーン描画し、案2のデザイン基準と比較した。
- 「バックアップを設定」は案内済みフラグを保存してデータ管理へ遷移する。
- 「あとで設定」は案内済みフラグを保存してシートを閉じる。
- 主操作にReturnキーの既定ショートカットを設定した。
- 詳細は `artifacts/v1-prep/design-qa/design-qa.md` を参照する。

## 外部ゲート

次の2項目は未完了のため、アプリ版は0.9.0のままとし、`v1.0.0`タグを作成しない。

1. 利用者環境のe-Tax WEBで、2025年分`.xtx`の実ファイル取込を完了する。
2. Developer ID署名、Apple公証、公式バイナリとチェックサムの公開を完了する。

Codex配下で生成したQAコピーは来歴属性の影響を受け、Launch Servicesが`-10827`で起動を拒否した。実行ファイルを直接起動するとアプリ登録前に停止するため、全アプリ遷移のGUI再確認は上記外部配布ゲート時に、Launch Services経由の正式な署名済みバンドルで行う。

## 配布資格の準備

2026-07-28、リリース担当者の通常ターミナルで
`notarytool history --keychain-profile blueprint-notary`が成功した。
これはNotary Service資格情報の準備完了を示すが、アプリ本体の署名、公証、
ticketのstaple完了を示すものではない。

正式リリースを開始する前に、追加した`release-preflight.sh`で次を確認する。

- Git worktreeに未commitの変更がない
- `Info.plist`と`BlueprintVersions.app`のバージョンが一致する
- 指定したDeveloper ID Application identityが使用できる
- 指定したNotary Service Keychain profileで履歴を取得できる

同日、配布スクリプト更新後に104件のテスト、production build、
自己ビルド用アプリバンドルのad-hoc署名検証、`Info.plist`検証を再実行し、
すべて成功した。
