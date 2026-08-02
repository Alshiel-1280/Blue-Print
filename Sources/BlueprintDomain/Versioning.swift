public enum BlueprintVersions {
  public static let app = "2.0.0"
  public static let databaseSchema = 1
  public static let dataFormat = 1
  public static let backupFormat = 1
  public static let backupFamily = "blueprint-v2"
  public static let storageGeneration = 2
  public static let taxRuleSet = "signed-bprules"
  public static let formRuleSet = "signed-bprules"
  public static let captureProtocol = 2

  #if BLUEPRINT_OFFICIAL_BUILD
    public static let buildOrigin = "official"
  #elseif BLUEPRINT_RELEASE
    public static let buildOrigin = "self-built release"
  #else
    public static let buildOrigin = "development / self-built"
  #endif
}

/// Constants used only by the explicit v1 restore reader and the retained v1 test fixtures.
/// The v2 application entry point never opens a database or backup using these values.
public enum BlueprintLegacyVersions {
  public static let app = "1.1.0"
  public static let databaseSchema = 9
  public static let dataFormat = 8
  public static let backupFormat = 9
  public static let storageGeneration = 1
  public static let taxRuleSet = "2025.1"
  public static let formRuleSet = "2025.1"
  public static let captureProtocol = 1
}
