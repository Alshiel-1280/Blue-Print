import BlueprintDomain
import BlueprintTransfer
import SwiftUI
import UniformTypeIdentifiers

private let blueprintArchiveType = UTType(
  exportedAs: "io.github.alshiel1280.blueprint.archive", conformingTo: .json)
private let blueprintBackupType = UTType(
  exportedAs: "io.github.alshiel1280.blueprint.backup", conformingTo: .json)

private enum DataManagementMode: String, CaseIterable, Identifiable {
  case migration = "弥生から移行"
  case archive = "出力・バックアップ"
  case diagnostics = "診断"

  var id: String { rawValue }
}

private enum DataImportKind {
  case yayoi
  case backup
}

struct DataManagementView: View {
  @ObservedObject var model: AppModel
  @State private var mode: DataManagementMode = .migration
  @State private var product: YayoiProduct = .desktopOrOnline
  @State private var importKind: DataImportKind?
  @State private var selectedImportKind: DataImportKind = .yayoi
  @State private var exportDocument: TransferExportDocument?
  @State private var exportType = UTType.json
  @State private var exportFilename = ""
  @State private var isExporting = false
  @State private var passphrase = ""
  @State private var restorePassphrase = ""
  @State private var restoreStaged = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let operation = model.activeOperation {
        HStack(spacing: 12) {
          ProgressView()
            .controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text(operation.title).font(.subheadline.weight(.semibold))
            Text(operation.detail).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text(operation.canCancel ? "取消可能" : "整合性維持のため完了まで取消不可")
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.indigo.opacity(0.08))
        .accessibilityElement(children: .combine)
      }
      switch mode {
      case .migration: migrationWorkspace
      case .archive: archiveWorkspace
      case .diagnostics: diagnosticsWorkspace
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
    .fileImporter(
      isPresented: Binding(
        get: { importKind != nil },
        set: { if !$0 { importKind = nil } }
      ),
      allowedContentTypes: importKind == .backup
        ? [backupType, .json] : [.commaSeparatedText, .plainText],
      allowsMultipleSelection: false,
      onCompletion: openSelectedFile
    )
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: exportType,
      defaultFilename: exportFilename
    ) { result in
      if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
      exportDocument = nil
    }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("データ管理")
          .font(.title.weight(.semibold))
        Text("移行、持ち出し、復元、破損診断をこのMac上で完結します。")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("表示", selection: $mode) {
        ForEach(DataManagementMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .frame(width: 430)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var migrationWorkspace: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker("弥生形式", selection: $product) {
          Text("デスクトップ／オンライン").tag(YayoiProduct.desktopOrOnline)
          Text("弥生会計 Next").tag(YayoiProduct.next)
        }
        .frame(width: 270)
        Button("弥生CSVを選択", systemImage: "square.and.arrow.down") {
          selectedImportKind = .yayoi
          importKind = .yayoi
        }
        Spacer()
        if let preview = model.yayoiMigrationPreview {
          statusChip("正常 \(preview.entries.count)件", color: .green)
          statusChip("隔離 \(preview.quarantinedRows.count)行", color: .orange)
          statusChip(
            "差額 \(yenData(preview.balanceDifference.yen))",
            color: preview.balanceDifference == .zero ? .green : .red)
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
      Divider()

      if let preview = model.yayoiMigrationPreview {
        HSplitView {
          mappingPane(preview)
            .frame(minWidth: 320, idealWidth: 380)
          previewPane(preview)
            .frame(minWidth: 500)
        }
      } else {
        ContentUnavailableView(
          "弥生データを安全に確認",
          systemImage: "arrow.left.arrow.right.square",
          description: Text("25／27列の仕訳形式とNextの6列期首残高形式に対応し、正常行と隔離行を分けて表示します。")
        )
      }
    }
  }

  private func mappingPane(_ preview: YayoiMigrationBatch) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("科目マッピング").font(.headline)
        Text("弥生の科目をBlue-Printの科目へ対応付けます。")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(18)
      Divider()
      List {
        Section("勘定科目") {
          ForEach(preview.accountMappings) { mapping in
            VStack(alignment: .leading, spacing: 7) {
              Text(mapping.sourceAccount).font(.subheadline.weight(.semibold))
              Picker(
                "取込先",
                selection: Binding(
                  get: { mapping.targetAccountID },
                  set: {
                    model.updateYayoiMapping(
                      sourceAccount: mapping.sourceAccount, targetAccountID: $0)
                  }
                )
              ) {
                Text("未設定").tag(EntityID?.none)
                ForEach(model.accounts.filter(\.isActive)) { account in
                  Text("\(account.code) \(account.name)").tag(EntityID?.some(account.id))
                }
              }
              .labelsHidden()
            }
            .padding(.vertical, 5)
          }
        }
        if !preview.subAccountMappings.isEmpty {
          Section("補助科目") {
            ForEach(preview.subAccountMappings) { mapping in
              VStack(alignment: .leading, spacing: 3) {
                Text("\(mapping.sourceAccount)／\(mapping.sourceSubAccount)")
                  .font(.subheadline.weight(.semibold))
                Text("取込時に「\(mapping.targetSubAccountName ?? mapping.sourceSubAccount)」を自動作成")
                  .font(.caption).foregroundStyle(.secondary)
              }
              .padding(.vertical, 4)
            }
          }
        }
      }
      Divider()
      VStack(spacing: 10) {
        HStack {
          Button("プレビューを取消", role: .cancel) { model.cancelYayoiMigration() }
          Spacer()
          Button("正常データを取り込む", systemImage: "checkmark.circle.fill") {
            model.commitYayoiMigration()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            preview.state == .cancelled || preview.entries.isEmpty
              || preview.accountMappings.contains { $0.targetAccountID == nil })
        }
        Text("取込はバッチ単位のトランザクションです。途中で失敗した場合は1件も保存しません。")
          .font(.caption2).foregroundStyle(.secondary)
      }
      .padding(16)
    }
  }

  private func previewPane(_ preview: YayoiMigrationBatch) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        sectionCard("残高比較", systemImage: "equal.circle") {
          HStack(spacing: 28) {
            metric("借方", preview.entries.reduce(0) { $0 + $1.debitTotal.yen })
            metric("貸方", preview.entries.reduce(0) { $0 + $1.creditTotal.yen })
            metric("差額", preview.balanceDifference.yen)
            Spacer()
          }
          Divider()
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
              Text("弥生科目").foregroundStyle(.secondary)
              Text("取込先").foregroundStyle(.secondary)
              Text("移行前").foregroundStyle(.secondary)
              Text("移行後").foregroundStyle(.secondary)
              Text("差額").foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(preview.accountBalanceComparison) { row in
              GridRow {
                Text(row.sourceAccount)
                Text(row.targetAccountName ?? "未設定")
                Text(yenData(row.sourceSignedDebitYen)).monospacedDigit()
                Text(row.targetSignedDebitYen.map(yenData) ?? "—").monospacedDigit()
                Text(row.differenceYen.map(yenData) ?? "—").monospacedDigit()
                  .foregroundStyle(row.differenceYen == 0 ? .green : .orange)
              }
              .font(.caption)
            }
          }
        }
        sectionCard("仕訳・期首残高プレビュー", systemImage: "list.bullet.rectangle") {
          if preview.entries.isEmpty {
            Text("取込可能なデータがありません。隔離理由を確認してください。")
              .foregroundStyle(.secondary)
          }
          ForEach(preview.entries) { entry in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                Text(entry.date, format: .dateTime.year().month().day())
                Text(entry.description).fontWeight(.semibold)
                Spacer()
                Text("\(entry.sourceRows.lowerBound)〜\(entry.sourceRows.upperBound)行")
                  .font(.caption).foregroundStyle(.secondary)
              }
              ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                HStack {
                  Text(line.side == .debit ? "借" : "貸")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(line.side == .debit ? .indigo : .orange)
                  Text(line.sourceAccount)
                  if let sub = line.sourceSubAccount { Text("／\(sub)").foregroundStyle(.secondary) }
                  Spacer()
                  Text(yenData(line.amount.yen)).monospacedDigit()
                }
                .font(.subheadline)
              }
            }
            .padding(.vertical, 8)
            if entry.id != preview.entries.last?.id { Divider() }
          }
        }
        if !preview.quarantinedRows.isEmpty {
          sectionCard("隔離した行", systemImage: "exclamationmark.triangle") {
            ForEach(preview.quarantinedRows) { row in
              VStack(alignment: .leading, spacing: 3) {
                Text("\(row.rowNumber)行: \(row.reason)").font(.subheadline.weight(.semibold))
                Text(row.rawRow).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(
                  2)
              }
              .padding(.vertical, 4)
            }
          }
        }
      }
      .padding(20)
    }
  }

  private var archiveWorkspace: some View {
    ScrollView {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(minimum: 240), spacing: 16), count: 3),
        spacing: 16
      ) {
        actionCard(
          title: "全データを持ち出す",
          detail: "全テーブルのJSON、証憑原本と索引、検証用SQLiteスナップショットを1ファイルへまとめます。",
          icon: "shippingbox",
          button: "アーカイブを書き出す"
        ) {
          model.preparePortableArchive { data in
            startExport(
              data: data,
              type: archiveType,
              filename: "BluePrint-全データ-\(model.fiscalYear?.calendarYear ?? 0)"
            )
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          Label("暗号化バックアップ", systemImage: "lock.shield")
            .font(.title3.weight(.semibold))
          Text("AES-256-GCMで改ざん検知付き暗号化を行います。パスフレーズはファイルへ保存しません。")
            .foregroundStyle(.secondary)
          SecureField("12文字以上のパスフレーズ", text: $passphrase)
            .textFieldStyle(.roundedBorder)
          Button("暗号化バックアップを作成", systemImage: "externaldrive.badge.plus") {
            model.prepareEncryptedBackup(passphrase: passphrase) { data in
              startExport(
                data: data,
                type: backupType,
                filename: "BluePrint-暗号化バックアップ"
              )
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.activeOperation != nil)
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("日次・7世代の自動バックアップ").font(.subheadline.weight(.semibold))
              Text("パスフレーズはこのMacのキーチェーンへ保存します。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.automaticBackupEnabled {
              Button("無効にする", role: .destructive) { model.disableAutomaticBackups() }
            } else {
              Button("有効にする") { model.enableAutomaticBackups(passphrase: passphrase) }
            }
          }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .dataCard()

        VStack(alignment: .leading, spacing: 14) {
          Label("復元前に内容を検証", systemImage: "arrow.counterclockwise.circle")
            .font(.title3.weight(.semibold))
          Text("件数・残高・証憑ハッシュと形式互換性を確認してから、次回起動時の復元を予約します。")
            .foregroundStyle(.secondary)
          SecureField("バックアップのパスフレーズ", text: $restorePassphrase)
            .textFieldStyle(.roundedBorder)
          Button("バックアップを選択", systemImage: "folder") {
            selectedImportKind = .backup
            importKind = .backup
          }
          if let preview = model.restorePreview {
            Divider()
            LabeledContent("作成日時", value: preview.manifest.createdAt.formatted())
            LabeledContent("証憑", value: "\(preview.manifest.evidenceCount)件")
            LabeledContent("形式", value: "v\(preview.manifest.formatVersion)")
            ForEach(preview.warnings, id: \.self) { warning in
              Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button("次回起動時の復元を予約", systemImage: "arrow.clockwise") {
              model.stageInspectedRestore()
              restoreStaged = model.errorMessage == nil
            }
            .buttonStyle(.borderedProminent)
            .disabled(!preview.isCompatible)
          }
          if restoreStaged {
            Label("復元を予約しました。アプリを終了し、もう一度起動してください。", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .dataCard()
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(24)
    }
  }

  private var diagnosticsWorkspace: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("DBと証憑原本を読み取り専用で検査します。").font(.headline)
          Text("SQLite整合性、仕訳残高、証憑件数とSHA-256を確認します。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("診断を実行", systemImage: "stethoscope") {
          model.runDataDiagnosticsInBackground()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.activeOperation != nil)
      }
      .padding(20)
      Divider()
      if let report = model.diagnosticReport {
        List {
          Section {
            LabeledContent("診断日時", value: report.createdAt.formatted())
            LabeledContent("証憑確認", value: "\(report.evidenceChecked)件")
            LabeledContent("結果", value: report.isHealthy ? "正常" : "要対応")
          }
          Section("診断項目") {
            ForEach(report.findings) { finding in
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: diagnosticIcon(finding.severity))
                  .foregroundStyle(diagnosticColor(finding.severity))
                VStack(alignment: .leading, spacing: 3) {
                  Text(finding.title).fontWeight(.semibold)
                  Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 4)
            }
          }
        }
        .listStyle(.inset)
      } else {
        ContentUnavailableView("診断はまだ実行されていません", systemImage: "stethoscope")
      }
    }
  }

  private func sectionCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage).font(.headline)
      Divider()
      content()
    }
    .dataCard()
  }

  private func actionCard(
    title: String,
    detail: String,
    icon: String,
    button: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: icon).font(.title3.weight(.semibold))
      Text(detail).foregroundStyle(.secondary)
      Button(button, systemImage: "square.and.arrow.up", action: action)
        .buttonStyle(.borderedProminent)
        .disabled(model.activeOperation != nil)
    }
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
    .dataCard()
  }

  private func metric(_ title: String, _ value: Int64) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(yenData(value)).font(.headline).monospacedDigit()
    }
  }

  private func statusChip(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(color.opacity(0.1), in: Capsule())
  }

  private func startExport(data: Data?, type: UTType, filename: String) {
    guard let data else { return }
    exportDocument = TransferExportDocument(data: data, type: type)
    exportType = type
    exportFilename = filename
    isExporting = true
  }

  private func openSelectedFile(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      if selectedImportKind == .backup {
        model.inspectEncryptedBackup(data: data, passphrase: restorePassphrase)
      } else {
        model.previewYayoiMigration(
          data: data, filename: url.lastPathComponent, product: product)
      }
      importKind = nil
    } catch {
      model.errorMessage = error.localizedDescription
      importKind = nil
    }
  }

  private var archiveType: UTType {
    blueprintArchiveType
  }

  private var backupType: UTType {
    blueprintBackupType
  }

  private func diagnosticIcon(_ severity: DiagnosticFinding.Severity) -> String {
    switch severity {
    case .information: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  private func diagnosticColor(_ severity: DiagnosticFinding.Severity) -> Color {
    switch severity {
    case .information: .green
    case .warning: .orange
    case .error: .red
    }
  }
}

private struct TransferExportDocument: FileDocument {
  static var readableContentTypes: [UTType] {
    [.data, .json, blueprintArchiveType, blueprintBackupType]
  }
  let data: Data
  let type: UTType

  init(data: Data, type: UTType) {
    self.data = data
    self.type = type
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
    type = configuration.contentType
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension View {
  fileprivate func dataCard() -> some View {
    padding(18)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
      )
  }
}

private func yenData(_ value: Int64) -> String {
  "¥" + value.formatted(.number.grouping(.automatic))
}
