# v0.8 Design QA

- Viewport: 1398 × 768
- Appearance: macOS dark appearance
- Direction: 案2のサイドバー、密度の高いヘッダー、セグメント切替、左右分割ワークスペース、状態チップを継承
- Migration: 正常2件・隔離1行、科目マッピング、借貸差額、仕訳明細、隔離理由、原子的取込を実画面で確認
- Backup: 全データ出力、暗号化、日次7世代、復元プレビューの3カードが同一画面に収まることを確認
- Diagnostics: SQLite整合性、証憑件数、結果、診断項目の表示を確認
- Interaction: サイドバー移動、3モード切替、弥生正常行の取込、診断実行を確認
- Fix during QA: 詳細領域の上部余白を除去し、複数のファイルインポーターを単一の選択フローへ統合
- Comparison: `reference-vs-migration.png` で案2参照と同じ1398 × 768の実装画面を並べ、レイアウト密度・分割・階層を確認
