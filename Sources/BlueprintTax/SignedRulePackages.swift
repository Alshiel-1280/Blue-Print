import BlueprintDomain
import CryptoKit
import Foundation

public enum RuleScope: String, Codable, CaseIterable, Hashable, Sendable {
  case bookkeeping
  case consumptionTax
  case closing
  case incomeTaxForm
  case xtx
}

public struct RulePackageManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let packageID: String
  public let calendarYear: Int
  public let revision: String
  public let scopes: Set<RuleScope>
  public let minimumAppVersion: String
  public let payloadSHA256: String
  public let keyID: String

  public init(
    schemaVersion: Int,
    packageID: String,
    calendarYear: Int,
    revision: String,
    scopes: Set<RuleScope>,
    minimumAppVersion: String,
    payloadSHA256: String,
    keyID: String
  ) {
    self.schemaVersion = schemaVersion
    self.packageID = packageID
    self.calendarYear = calendarYear
    self.revision = revision
    self.scopes = scopes
    self.minimumAppVersion = minimumAppVersion
    self.payloadSHA256 = payloadSHA256
    self.keyID = keyID
  }
}

public struct InvoiceDeductionRule: Codable, Equatable, Sendable {
  public let firstTransactionDate: String
  public let lastTransactionDate: String?
  public let deductibleRateBasisPoints: Int
  public let annualSupplierPurchaseLimitYen: Int64?
  public let limitAppliesToTaxPeriodsStartingOnOrAfter: String?

  public init(
    firstTransactionDate: String,
    lastTransactionDate: String?,
    deductibleRateBasisPoints: Int,
    annualSupplierPurchaseLimitYen: Int64? = nil,
    limitAppliesToTaxPeriodsStartingOnOrAfter: String? = nil
  ) {
    self.firstTransactionDate = firstTransactionDate
    self.lastTransactionDate = lastTransactionDate
    self.deductibleRateBasisPoints = deductibleRateBasisPoints
    self.annualSupplierPurchaseLimitYen = annualSupplierPurchaseLimitYen
    self.limitAppliesToTaxPeriodsStartingOnOrAfter =
      limitAppliesToTaxPeriodsStartingOnOrAfter
  }
}

public struct InvoiceDeductionContext: Equatable, Sendable {
  public let transactionDate: Date
  public let taxPeriodStart: Date
  public let supplierAnnualPurchasesYen: Int64
  public let invoiceStatus: InvoiceRegistrationStatus
  public let taxRate: TaxRate

  public init(
    transactionDate: Date,
    taxPeriodStart: Date,
    supplierAnnualPurchasesYen: Int64,
    invoiceStatus: InvoiceRegistrationStatus,
    taxRate: TaxRate
  ) {
    self.transactionDate = transactionDate
    self.taxPeriodStart = taxPeriodStart
    self.supplierAnnualPurchasesYen = supplierAnnualPurchasesYen
    self.invoiceStatus = invoiceStatus
    self.taxRate = taxRate
  }
}

public struct InvoiceDeductionDecision: Equatable, Sendable {
  public let deductibleRateBasisPoints: Int
  public let reason: String

  public init(deductibleRateBasisPoints: Int, reason: String) {
    self.deductibleRateBasisPoints = deductibleRateBasisPoints
    self.reason = reason
  }
}

public enum InvoiceDeductionEvaluator {
  public static func evaluate(
    context: InvoiceDeductionContext,
    rules: [InvoiceDeductionRule]
  ) -> InvoiceDeductionDecision {
    guard context.taxRate.basisPoints != nil else {
      return InvoiceDeductionDecision(
        deductibleRateBasisPoints: 0,
        reason: "非課税・対象外の税区分"
      )
    }
    if context.invoiceStatus == .qualified {
      return InvoiceDeductionDecision(
        deductibleRateBasisPoints: 10_000,
        reason: "適格請求書発行事業者"
      )
    }
    guard context.invoiceStatus == .exemptOrUnregistered else {
      return InvoiceDeductionDecision(
        deductibleRateBasisPoints: 0,
        reason: "登録区分が未確認"
      )
    }
    guard let rule = rules.first(where: { contains($0, context.transactionDate) }) else {
      return InvoiceDeductionDecision(
        deductibleRateBasisPoints: 0,
        reason: "取引日に対応する経過措置なし"
      )
    }
    if let limit = rule.annualSupplierPurchaseLimitYen,
      let thresholdText = rule.limitAppliesToTaxPeriodsStartingOnOrAfter,
      let threshold = parse(thresholdText),
      context.taxPeriodStart >= threshold,
      context.supplierAnnualPurchasesYen > limit
    {
      return InvoiceDeductionDecision(
        deductibleRateBasisPoints: 0,
        reason: "課税期間と年間取引額の上限条件に該当"
      )
    }
    return InvoiceDeductionDecision(
      deductibleRateBasisPoints: rule.deductibleRateBasisPoints,
      reason: "免税事業者等からの課税仕入れに関する経過措置"
    )
  }

  private static func contains(_ rule: InvoiceDeductionRule, _ date: Date) -> Bool {
    guard let first = parse(rule.firstTransactionDate), date >= first else { return false }
    guard let lastText = rule.lastTransactionDate else { return true }
    guard let last = parse(lastText) else { return false }
    let exclusiveEnd =
      Calendar(identifier: .gregorian).date(
        byAdding: .day,
        value: 1,
        to: last
      ) ?? last
    return date < exclusiveEnd
  }

  private static func parse(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }
}

public struct RulePackagePayload: Codable, Equatable, Sendable {
  public let taxRuleSet: TaxRuleSet?
  public let formRuleSet: FormRuleSet?
  public let invoiceDeductionRules: [InvoiceDeductionRule]

  public init(
    taxRuleSet: TaxRuleSet?,
    formRuleSet: FormRuleSet?,
    invoiceDeductionRules: [InvoiceDeductionRule] = []
  ) {
    self.taxRuleSet = taxRuleSet
    self.formRuleSet = formRuleSet
    self.invoiceDeductionRules = invoiceDeductionRules
  }
}

public struct VerifiedRulePackage: Equatable, Sendable {
  public enum Origin: String, Equatable, Sendable {
    case bundled
    case installed
  }

  public let manifest: RulePackageManifest
  public let payload: RulePackagePayload
  public let origin: Origin

  public init(
    manifest: RulePackageManifest,
    payload: RulePackagePayload,
    origin: Origin
  ) {
    self.manifest = manifest
    self.payload = payload
    self.origin = origin
  }
}

public enum RulePackageVerificationFailure: Error, Equatable, Sendable {
  case missingFile(String)
  case malformedManifest
  case malformedPayload
  case unsupportedSchema(Int)
  case unknownKey(String)
  case invalidPayloadHash
  case invalidSignature
  case yearMismatch
  case scopeContentMismatch
  case duplicatePackage(String)
  case downgradeAttempt(current: String, candidate: String)
}

public enum RuleVerificationResult: Equatable, Sendable {
  case verified(VerifiedRulePackage)
  case rejected(RulePackageVerificationFailure)
}

public struct TrustedRuleKey: Equatable, Sendable {
  public let id: String
  public let rawRepresentation: Data

  public init(id: String, rawRepresentation: Data) {
    self.id = id
    self.rawRepresentation = rawRepresentation
  }
}

public struct YearSupportMatrix: Equatable, Sendable {
  public let calendarYear: Int
  public let supportedScopes: Set<RuleScope>
  public let packageRevision: String

  public init(
    calendarYear: Int,
    supportedScopes: Set<RuleScope>,
    packageRevision: String
  ) {
    self.calendarYear = calendarYear
    self.supportedScopes = supportedScopes
    self.packageRevision = packageRevision
  }

  public func supports(_ scope: RuleScope) -> Bool {
    supportedScopes.contains(scope)
  }
}

public struct RulePackageVerifier: Sendable {
  public static let supportedSchemaVersion = 1

  private let keys: [String: TrustedRuleKey]

  public init(trustedKeys: [TrustedRuleKey]) {
    keys = Dictionary(uniqueKeysWithValues: trustedKeys.map { ($0.id, $0) })
  }

  public func verify(
    manifestData: Data,
    payloadData: Data,
    signatureData: Data,
    origin: VerifiedRulePackage.Origin
  ) -> RuleVerificationResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(RulePackageManifest.self, from: manifestData) else {
      return .rejected(.malformedManifest)
    }
    guard manifest.schemaVersion == Self.supportedSchemaVersion else {
      return .rejected(.unsupportedSchema(manifest.schemaVersion))
    }
    guard Self.sha256(payloadData) == manifest.payloadSHA256 else {
      return .rejected(.invalidPayloadHash)
    }
    guard let payload = try? decoder.decode(RulePackagePayload.self, from: payloadData) else {
      return .rejected(.malformedPayload)
    }
    guard let trustedKey = keys[manifest.keyID],
      let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: trustedKey.rawRepresentation)
    else {
      return .rejected(.unknownKey(manifest.keyID))
    }
    guard publicKey.isValidSignature(signatureData, for: manifestData) else {
      return .rejected(.invalidSignature)
    }
    guard payload.taxRuleSet?.effectivePeriod.contains(manifest.calendarYear) ?? true,
      payload.formRuleSet?.effectivePeriod.contains(manifest.calendarYear) ?? true
    else {
      return .rejected(.yearMismatch)
    }
    guard Self.scopesMatchPayload(manifest: manifest, payload: payload) else {
      return .rejected(.scopeContentMismatch)
    }
    return .verified(
      VerifiedRulePackage(manifest: manifest, payload: payload, origin: origin))
  }

  private static func scopesMatchPayload(
    manifest: RulePackageManifest,
    payload: RulePackagePayload
  ) -> Bool {
    if manifest.scopes.contains(.bookkeeping) && payload.taxRuleSet == nil { return false }
    if manifest.scopes.contains(.incomeTaxForm) && payload.formRuleSet == nil { return false }
    if manifest.scopes.contains(.xtx) && payload.formRuleSet == nil { return false }
    if payload.formRuleSet != nil
      && !manifest.scopes.contains(.incomeTaxForm)
      && !manifest.scopes.contains(.xtx)
    {
      return false
    }
    return true
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct RuleCatalogStore: Sendable {
  public let packages: [VerifiedRulePackage]

  public init(packages: [VerifiedRulePackage]) throws {
    var seen = Set<String>()
    for package in packages {
      guard seen.insert(package.manifest.packageID).inserted else {
        throw RulePackageVerificationFailure.duplicatePackage(package.manifest.packageID)
      }
    }
    self.packages = packages.sorted {
      if $0.manifest.calendarYear != $1.manifest.calendarYear {
        return $0.manifest.calendarYear < $1.manifest.calendarYear
      }
      return $0.manifest.revision.compare(
        $1.manifest.revision,
        options: .numeric
      ) == .orderedAscending
    }
  }

  public init(
    bundledDirectory: URL,
    installedDirectory: URL? = nil,
    trustedKeys: [TrustedRuleKey],
    fileManager: FileManager = .default
  ) throws {
    let verifier = RulePackageVerifier(trustedKeys: trustedKeys)
    var loaded = try Self.loadPackages(
      in: bundledDirectory,
      origin: .bundled,
      verifier: verifier,
      fileManager: fileManager
    )
    if let installedDirectory,
      fileManager.fileExists(atPath: installedDirectory.path)
    {
      let installed = try Self.loadPackages(
        in: installedDirectory,
        origin: .installed,
        verifier: verifier,
        fileManager: fileManager
      )
      for candidate in installed {
        if let current = loaded.first(where: {
          $0.manifest.calendarYear == candidate.manifest.calendarYear
        }) {
          guard
            candidate.manifest.revision.compare(
              current.manifest.revision,
              options: .numeric
            ) != .orderedAscending
          else {
            throw RulePackageVerificationFailure.downgradeAttempt(
              current: current.manifest.revision,
              candidate: candidate.manifest.revision
            )
          }
          loaded.removeAll {
            $0.manifest.calendarYear == candidate.manifest.calendarYear
          }
        }
        loaded.append(candidate)
      }
    }
    try self.init(packages: loaded)
  }

  public var supportedYears: [Int] {
    packages.map(\.manifest.calendarYear)
  }

  public var latestSupportedYear: Int {
    supportedYears.max() ?? 2025
  }

  public var supportMatrix: [YearSupportMatrix] {
    packages.map {
      YearSupportMatrix(
        calendarYear: $0.manifest.calendarYear,
        supportedScopes: $0.manifest.scopes,
        packageRevision: $0.manifest.revision
      )
    }
  }

  public var catalog: RuleCatalog {
    RuleCatalog(
      taxRuleSets: packages.compactMap(\.payload.taxRuleSet),
      formRuleSets: packages.compactMap(\.payload.formRuleSet)
    )
  }

  public func package(for year: Int) throws -> VerifiedRulePackage {
    guard let package = packages.first(where: { $0.manifest.calendarYear == year }) else {
      throw RuleSetError.unsupportedYear(year)
    }
    return package
  }

  public func taxRule(for year: Int) throws -> TaxRuleSet {
    guard let rule = try package(for: year).payload.taxRuleSet else {
      throw RuleSetError.unsupportedYear(year)
    }
    return rule
  }

  public func formRule(for year: Int) throws -> FormRuleSet {
    guard let rule = try package(for: year).payload.formRuleSet else {
      throw RuleSetError.unsupportedYear(year)
    }
    return rule
  }

  public func rules(for year: Int) throws -> (TaxRuleSet, FormRuleSet) {
    (try taxRule(for: year), try formRule(for: year))
  }

  public func support(for year: Int) -> YearSupportMatrix? {
    supportMatrix.first { $0.calendarYear == year }
  }

  private static func loadPackages(
    in directory: URL,
    origin: VerifiedRulePackage.Origin,
    verifier: RulePackageVerifier,
    fileManager: FileManager
  ) throws -> [VerifiedRulePackage] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let children = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    return try children.compactMap { child in
      let values = try child.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true, child.pathExtension == "bprules" else { return nil }
      let manifestURL = child.appendingPathComponent("manifest.json")
      let payloadURL = child.appendingPathComponent("payload.json")
      let signatureURL = child.appendingPathComponent("signature.ed25519")
      guard fileManager.fileExists(atPath: manifestURL.path) else {
        throw RulePackageVerificationFailure.missingFile(manifestURL.lastPathComponent)
      }
      guard fileManager.fileExists(atPath: payloadURL.path) else {
        throw RulePackageVerificationFailure.missingFile(payloadURL.lastPathComponent)
      }
      guard fileManager.fileExists(atPath: signatureURL.path) else {
        throw RulePackageVerificationFailure.missingFile(signatureURL.lastPathComponent)
      }
      let manifestData = try Data(contentsOf: manifestURL)
      let payloadData = try Data(contentsOf: payloadURL)
      let signatureText = try String(contentsOf: signatureURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let signatureData = Data(base64Encoded: signatureText) else {
        throw RulePackageVerificationFailure.invalidSignature
      }
      switch verifier.verify(
        manifestData: manifestData,
        payloadData: payloadData,
        signatureData: signatureData,
        origin: origin
      ) {
      case .verified(let package):
        return package
      case .rejected(let failure):
        throw failure
      }
    }
  }
}

public enum OfficialRulePackages {
  private static var bundledDirectory: URL {
    let bundleName = "BluePrint_BlueprintTax.bundle"
    var candidates: [URL] = []

    if let appResources = Bundle.main.resourceURL {
      candidates.append(
        appResources
          .appendingPathComponent(bundleName, isDirectory: true)
          .appendingPathComponent("RulePackages", isDirectory: true)
      )
    }

    // `swift run` and `swift test` place SwiftPM resource bundles beside a
    // build product rather than inside a macOS Contents/Resources directory.
    // Walk only the nearby executable hierarchy so this development lookup
    // cannot escape into unrelated user data.
    if var searchDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
      for _ in 0..<5 {
        candidates.append(
          searchDirectory
            .appendingPathComponent(bundleName, isDirectory: true)
            .appendingPathComponent("RulePackages", isDirectory: true)
        )
        searchDirectory.deleteLastPathComponent()
      }
    }

    // This final candidate keeps direct module/unit-test execution usable when
    // a test runner relocates its executable away from SwiftPM's build folder.
    candidates.append(
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/RulePackages", isDirectory: true)
    )

    guard
      let resourceRoot = candidates.first(where: {
        FileManager.default.fileExists(
          atPath: $0.appendingPathComponent("trusted-key.b64").path
        )
      })
    else {
      fatalError(
        "Bundled rule package resources are unavailable in the signed application resources"
      )
    }
    return resourceRoot
  }

  public static let trustedReleaseKey: TrustedRuleKey = {
    let keyURL = bundledDirectory.appendingPathComponent("trusted-key.b64")
    guard
      let keyText = try? String(contentsOf: keyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let publicKey = Data(base64Encoded: keyText)
    else {
      fatalError("Bundled rule public key is unavailable")
    }
    return TrustedRuleKey(id: "bundled-v1.1", rawRepresentation: publicKey)
  }()

  public static let store: RuleCatalogStore = {
    do {
      return try RuleCatalogStore(
        bundledDirectory: bundledDirectory,
        trustedKeys: [trustedReleaseKey]
      )
    } catch {
      fatalError("Bundled rule package verification failed: \(error)")
    }
  }()

  public static var supportedYears: [Int] { store.supportedYears }
  public static var latestSupportedYear: Int { store.latestSupportedYear }
  public static var supportMatrix: [YearSupportMatrix] { store.supportMatrix }

  public static func makeStore(installedDirectory: URL?) throws -> RuleCatalogStore {
    try RuleCatalogStore(
      bundledDirectory: bundledDirectory,
      installedDirectory: installedDirectory,
      trustedKeys: [trustedReleaseKey]
    )
  }
}
