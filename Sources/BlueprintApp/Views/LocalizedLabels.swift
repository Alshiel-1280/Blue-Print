import BlueprintAudit
import BlueprintDocuments
import BlueprintDomain
import BlueprintImports
import BlueprintTax

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

extension EvidenceOrigin {
  var localizedName: String {
    switch self {
    case .paperScan: "紙スキャン"
    case .electronicTransaction: "電子取引"
    case .cameraCapture: "カメラ取込"
    }
  }
}

extension EvidenceState {
  var localizedName: String {
    switch self {
    case .unprocessed: "未処理"
    case .needsReview: "確認待ち"
    case .posted: "転記済み"
    case .excluded: "対象外"
    }
  }
}

extension ImportedTransactionState {
  var localizedName: String {
    switch self {
    case .unprocessed: "未処理"
    case .needsReview: "確認待ち"
    case .posted: "転記済み"
    case .excluded: "対象外"
    }
  }
}

extension OCRField {
  var localizedName: String {
    switch self {
    case .transactionDate: "取引日"
    case .amount: "金額"
    case .counterparty: "取引先"
    case .invoiceRegistrationNumber: "登録番号"
    case .taxRate: "税率"
    }
  }
}

extension TaxSelection {
  var localizedName: String {
    switch self {
    case .standard10Qualified: "10%・適格"
    case .standard10Unregistered: "10%・免税／未登録"
    case .reduced8Qualified: "8%軽減・適格"
    case .reduced8Unregistered: "8%軽減・免税／未登録"
    case .exempt: "非課税"
    case .outOfScope: "不課税・対象外"
    }
  }
}

extension CSVEncoding {
  var localizedName: String {
    switch self {
    case .utf8: "UTF-8"
    case .shiftJIS: "Shift-JIS"
    }
  }
}

extension CSVDelimiter {
  var localizedName: String {
    switch self {
    case .comma: "カンマ区切り"
    case .tab: "タブ区切り"
    case .semicolon: "セミコロン区切り"
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

extension InvoiceRegistrationStatus {
  var v2LocalizedName: String {
    switch self {
    case .qualified: "適格請求書発行事業者"
    case .exemptOrUnregistered: "免税・未登録"
    case .unknown: "未確認"
    }
  }
}

extension BackgroundJobKind {
  var v2LocalizedName: String {
    switch self {
    case .ocr: "証憑OCR"
    case .dataImport: "データ取込"
    case .matching: "証憑照合"
    case .backup: "バックアップ"
    case .xtxGeneration: "XTX生成"
    }
  }
}

extension BackgroundJobState {
  var v2LocalizedName: String {
    switch self {
    case .queued: "待機中"
    case .running: "実行中"
    case .succeeded: "完了"
    case .failed: "失敗"
    case .cancelled: "取消"
    }
  }
}

extension JournalCandidateStateV2 {
  var v2LocalizedName: String {
    switch self {
    case .pending: "確認待ち"
    case .confirmed: "確定済み"
    case .rejected: "却下"
    }
  }
}

extension ClosingDecisionStateV2 {
  var v2LocalizedName: String {
    switch self {
    case .pending: "判断待ち"
    case .confirmed: "確認済み"
    case .notApplicable: "対象外"
    }
  }
}

extension JournalEntryStatus {
  var v2LocalizedName: String {
    switch self {
    case .draft: "下書き"
    case .pendingReview: "確認待ち"
    case .posted: "転記済み"
    case .reversed: "取消済み"
    case .corrected: "訂正済み"
    }
  }
}

extension InvoiceStatus {
  var v2LocalizedName: String {
    switch self {
    case .draft: "下書き"
    case .issued: "発行済み"
    case .partiallyPaid: "一部入金"
    case .paid: "入金済み"
    case .cancelled: "取消"
    case .overdue: "期限超過"
    case .corrected: "訂正済み"
    case .refunded: "返金済み"
    }
  }
}

extension RuleScope {
  var v2LocalizedName: String {
    switch self {
    case .bookkeeping: "記帳"
    case .consumptionTax: "消費税"
    case .closing: "決算"
    case .incomeTaxForm: "所得税帳票"
    case .xtx: "XTX"
    }
  }
}
