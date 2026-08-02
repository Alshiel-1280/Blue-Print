# ADR-008: 公式配布・署名・更新

- 状態: 採用
- 日付: 2026-07-21
- 対象: NFR-CMP-005、FR-OSS-006

## 判断

公式版は GitHub Releases でソース、署名・公証済み `.dmg`、SHA-256 チェックサムを公開する。Developer ID Application で署名し、Apple Notary Service で公証する。

自動更新によるバイナリ置換は行わない。利用者が「更新を確認」を押した時だけ
通信し、Ed25519署名付き更新マニフェストを検証して通知する。バックグラウンド
通信、テレメトリ、自動置換は行わない。

リリースは.appをHardened RuntimeとApp Sandbox entitlement付きで署名し、
DMGコンテナ自体も署名してから公証する。DMGへステープルし、DMGと.appの双方を
Gatekeeperで検証する。
