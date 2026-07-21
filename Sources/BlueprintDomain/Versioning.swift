public enum BlueprintVersions {
  public static let app = "0.9.0"
  public static let databaseSchema = 9
  public static let dataFormat = 8
  public static let taxRuleSet = "2025.1"
  public static let formRuleSet = "2025.1"
  public static let captureProtocol = 1

  #if BLUEPRINT_OFFICIAL_BUILD
    public static let buildOrigin = "official"
  #elseif BLUEPRINT_RELEASE
    public static let buildOrigin = "self-built release"
  #else
    public static let buildOrigin = "development / self-built"
  #endif
}
