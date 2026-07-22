# Design QA — v1準備 初回バックアップ案内

## Source truth and implementation

- Design-system source: `docs/design/option-2-unified-direction.png`（1487 × 1058 px）
- Implementation render: `artifacts/v1-prep/design-qa/backup-onboarding.png`（1120 × 612 px、560 pt幅、2x相当、ライト表示）
- Full comparison: `artifacts/v1-prep/design-qa/reference-vs-backup-onboarding.png`
- State: 初回案内、操作前、既定フォーカスは「バックアップを設定」

参照画像は月次タスク画面であり、初回案内と同一内容・同一状態ではない。そのためピクセル単位の画面一致ではなく、案2のデザインシステム（白い面、明確な見出し、青い主操作、抑制した副操作、高密度な説明、意味色）を比較対象とした。

## Comparison

- Typography: 太い主見出し、グレーの補足、本文より小さい注意文で、案2と同じ情報階層になっている。
- Spacing: 28 ptの外周余白、22 ptの主要ブロック間隔、12 ptの箇条書き間隔で、読み順が崩れない。
- Colors: 主操作はシステムの青、バックアップの象徴はインディゴ、注意は低彩度の橙背景とし、案2の青／橙の意味色へ揃えた。
- Assets: SF Symbolsのみを使用し、画面密度とmacOS標準コントロールの見た目を維持した。
- Copy: Macを正本とすること、暗号化、世代管理、復元検証、パスフレーズ紛失時の危険を一画面で説明している。
- Actions: 主操作は右下、副操作は左下に置き、Returnキーの既定操作を主操作へ設定した。主操作はデータ管理へ遷移し、副操作は案内を閉じる実装である。

初回レンダーでは透明背景により文字とボタンが正しく評価できなかったため、白いウインドウ背景を明示し、`ImageRenderer`から`NSHostingView`の実コントロール描画へ変更して再比較した。最終比較では、切れ、重なり、不正な余白、誤った主従関係はない。

P0、P1、P2の未解決事項はない。

final result: passed
