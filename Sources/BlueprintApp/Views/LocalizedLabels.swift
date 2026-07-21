import BlueprintAudit
import BlueprintDomain

extension AccountCategory {
  var localizedName: String {
    switch self {
    case .asset: "資産"
    case .liability: "負債"
    case .equity: "純資産"
    case .revenue: "収益"
    case .expense: "費用"
    }
  }
}

extension TaxRate {
  var localizedName: String {
    switch self {
    case .standard10: "10%"
    case .reduced8: "8%軽減"
    case .exempt: "非課税"
    case .outOfScope: "対象外"
    }
  }
}

extension AuditAction {
  var localizedName: String {
    switch self {
    case .created: "作成"
    case .updated: "更新"
    case .deactivated: "無効化"
    case .cancelled: "取消"
    case .corrected: "訂正"
    case .fiscalYearLocked: "年度ロック"
    case .fiscalYearReopened: "年度再オープン"
    case .migrationStarted: "移行開始"
    case .migrationCompleted: "移行完了"
    }
  }
}
