public enum BlueprintVersions {
  public static let app = "0.7.0"
  public static let databaseSchema = 8
  public static let dataFormat = 7
  public static let taxRuleSet = "2025.1"
  public static let formRuleSet = "2025.1"
  public static let captureProtocol = 1

  #if BLUEPRINT_RELEASE
    public static let buildOrigin = "official-candidate"
  #else
    public static let buildOrigin = "development"
  #endif
}
