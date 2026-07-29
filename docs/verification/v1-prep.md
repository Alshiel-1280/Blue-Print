# v1準備検証記録

実施日: 2026-07-22（最終更新: 2026-07-29）

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

e-Tax WEB実地読込、Developer ID署名、Apple公証、staple、ローカルおよび
別MacのGatekeeper確認が完了した。アプリ版は1.0.0（build 10）。
`v1.0.0`タグとGitHub Releaseの公開確認まで完了した。

### e-Tax WEB実地読込

2026-07-28、利用者環境のmacOS 15.7.7／Safari 18.6で、
Blue-Printが生成した2025年分`.xtx`をe-Taxソフト（WEB版）へ読み込んだ。
「データの表示」画面まで進み、所得税申告書、青色申告決算書（一般用）、
青色申告決算書（不動産所得用）が帳票として展開されたため、
対象年度の実地読込ゲートを合格とした。

この合格はファイル形式と帳票展開の確認であり、電子署名・送信の完了や
申告内容の税務上の正しさを意味しない。送信前に帳票PDFで年度、本人情報、
所得・控除・決算金額を利用者が確認する。

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

## 申告年度の安全な修正

初回設定が実行日の2026年を既定値にしていたため、2025年分だけを対象とする
v1候補で未対応年度を選びやすい問題を修正した。

- 初回設定の既定値を最新の対応年度である2025年に変更
- 事業者設定へ対応年度の選択と修正操作を追加
- 仕訳、証憑、インポート、請求、決算、申告、e-Tax出力、弥生移行の
  データが存在するときはDB境界で年度変更を拒否
- 年度と税務・帳票ルールIDを同一トランザクションで更新
- 変更元、変更先、適用ルールを監査記録へ保存
- 実際の起動時と同様に空の申告ワークスペースが存在する状態でも変更できることを確認
- 年度データ作成後は変更できず、元の年度を保持することを確認

変更後は全106件のテスト、release build、自己ビルド用アプリバンドルの
ad-hoc署名と`Info.plist`検証が成功した。

実データで年度修正ボタンが無効になる事象をGUIで再現し、安全判定を追加修正した。
家事按分ルールと決算テンプレートは年度に属さない再利用可能なマスターとして
年度変更を妨げない。棚卸データは期首・仕入・期末がすべて0円なら空とみなし、
いずれかに金額があれば引き続き年度変更を拒否する。

修正版をLaunch Servicesが実際に選択していた`.build/app/BluePrint.app`へ
再パッケージして起動し、2025年選択後に年度修正ボタンが有効になることを
アクセシビリティツリーで確認した。確定操作は行っていない。
追加後は全107件のテストが成功した。

## v1.0.0署名候補

2026-07-28、署名対象をアプリ版1.0.0、build 10へ更新した。

- `plutil -lint Resources/Info.plist`: 成功
- `swift format lint --recursive --strict Sources Tests Package.swift`: 成功
- `swift test`: 107件成功、失敗0件
- `swift build -c release`: 成功
- `git diff --check`: 成功

Developer ID署名、公証、staple、Gatekeeper検証は、この候補をcommitして
worktreeをクリーンにした後に実行する。

## v1.0.0配布検証

2026-07-28から29日に、commit `c3f2223`から公式成果物を生成した。

- Developer ID Application署名、Hardened Runtime、secure timestamp: 成功
- Apple Notary Service submission `11edf830-20c8-4fb3-9e97-ea9b3dd54368`:
  `Accepted`
- `stapler staple`および`stapler validate`: 成功
- ローカルGatekeeper: `accepted`、`source=Notarized Developer ID`
- ZIPを別ディレクトリへ展開した後の署名、ticket、Gatekeeper: 成功
- `CFBundleShortVersionString`: 1.0.0
- `CFBundleVersion`: 10
- 配布ZIP SHA-256:
  `90b492fed3b54713805e3a934b636529642add983f5d04d5013e6ccc6c7c89ad`
- 別MacへZIPとチェックサムを移し、利用者が通常起動できることを確認

e-Tax WEB版のPDF表示は長時間完了しなかったためスキップした。XTXの読込と
帳票展開は合格とするが、PDF内容の実地照合は未完了としてリリースノートへ
明記した。

## v1.0.0公開確認

2026-07-29、次を確認した。

- 注釈付き`v1.0.0`タグはcommit `7b82445`を指す
- GitHub Release名は`Blue-Print 1.0.0`
- Releaseは非ドラフト、非プレリリース
- 公証済みZIPとSHA-256ファイルは公開URLから認証なしで取得可能
- 公開URLから再取得したZIPのSHA-256はリリースノートと一致
- 公開ZIPを展開後、署名、stapled ticket、Gatekeeperを再検証
- 公開ZIPのアプリ版は1.0.0、build 10

公開先:
<https://github.com/Alshiel-1280/Blue-Print/releases/tag/v1.0.0>
