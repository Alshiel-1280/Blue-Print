# Design QA — v0.1 勘定科目

## Source and implementation

- Source: `artifacts/v0.1/design-qa/account-reference.png`
- Normalized source (1400 × 768): `artifacts/v0.1/design-qa/account-reference-1400x768.png`
- Implementation: `artifacts/v0.1/design-qa/account-screen-final.png`
- Full comparison: `artifacts/v0.1/design-qa/account-comparison-final.png`
- Focused header/table comparison: `artifacts/v0.1/design-qa/account-comparison-header-final.png`
- Viewport and state: 1400 × 768、2026年度、標準勘定科目15件、選択なし、アクティブウインドウ

## Findings and comparison history

1. 初回比較では、見出し階層、主操作の強さ、表の密度が参照より弱かった。
2. 見出しを30ptへ、主操作をlargeのbordered prominentへ、表を15pt・最小行高48ptへ調整した。
3. 再比較で、左サイドバー、上部説明、主操作、列構造、状態表現、下部操作の視覚階層が案2のネイティブmacOS会計ワークベンチへ揃った。
4. 参照のカレンダー、検索、表示設定、行メニューはv0.1の機能範囲外であり、今後の帳簿・検索機能で統合する。現段階ではP3の機能拡張差分で、v0.1の主要操作を妨げない。
5. 実装は標準科目15件を一画面で比較しやすくするため、参照より高密度である。ユーザーが選択した案2の「密度の高いプロ向け台帳」を優先した意図的な差分である。

P0、P1、P2の未解決事項はない。

## Primary interactions tested

- 必須項目が空の間は「帳簿を作成」が無効で、入力後に有効になる。
- 初回セットアップから事業者・年度・標準勘定科目を作成できる。
- 標準勘定科目15件を重複なく表示できる。
- 科目を選択し、無効化確認を経て物理削除せず無効化できる。
- 監査記録に初期作成と科目無効化が表示される。
- 再起動後もセットアップ済み状態と無効化状態が保持される。
- VoiceOverの見出し、表の行・列、ボタン、状態テキストがアクセシビリティツリーに公開される。

ネイティブmacOSアプリのためブラウザコンソールは対象外。起動、主要操作、再起動でアプリ内エラー表示およびクラッシュは発生しなかった。

## v0.2 会計コア追加画面

- Design-system source: `docs/design/option-2-unified-direction.png`
- Transaction input: `artifacts/v0.2/design-qa/transaction-input.png`
- Journal and reversal state: `artifacts/v0.2/design-qa/journal-reversed.png`
- Trial balance: `artifacts/v0.2/design-qa/trial-balance.png`
- Viewport: 1400 × 768、2026年度、アクティブウインドウ

v0.1で合格した案2のサイドバー、30pt見出し、白背景、高密度テーブル、青い主操作、緑／橙の状態表現を再利用した。取引入力は行指向の貸借ワークベンチ、仕訳帳・元帳・試算表は同じ列密度と操作位置へ統一した。生成済みの統合方向画像は月次ワークフロー状態のため画面内容のピクセル比較には使わず、共通シェル、文字階層、色、密度、状態表現を対象に比較した。

GUI確認で、空入力時の記帳無効、差額表示、取消理由の必須化、反対仕訳の追加、元仕訳の「取消済み」表示、試算表の貸借一致を確認した。P0、P1、P2の未解決事項はない。

final result: passed
