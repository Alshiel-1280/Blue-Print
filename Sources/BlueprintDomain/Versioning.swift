public enum BlueprintVersions {
  public static let app = "0.4.0"
  public static let databaseSchema = 5
  public static let dataFormat = 4
  public static let taxRuleSet = "2026.1-draft"
  public static let formRuleSet = "2026.1-draft"
  public static let captureProtocol = 1

  #if BLUEPRINT_RELEASE
    public static let buildOrigin = "official-candidate"
  #else
    public static let buildOrigin = "development"
  #endif
}
