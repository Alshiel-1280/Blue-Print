// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BluePrint",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "BlueprintDomain", targets: ["BlueprintDomain"]),
    .library(name: "BlueprintAudit", targets: ["BlueprintAudit"]),
    .library(name: "BlueprintPersistence", targets: ["BlueprintPersistence"]),
    .library(name: "BlueprintSharedCapture", targets: ["BlueprintSharedCapture"]),
    .executable(name: "BluePrint", targets: ["BlueprintApp"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "BlueprintDomain"),
    .target(
      name: "BlueprintAudit",
      dependencies: ["BlueprintDomain"]
    ),
    .target(name: "BlueprintSharedCapture"),
    .target(
      name: "BlueprintPersistence",
      dependencies: ["BlueprintDomain", "BlueprintAudit", "BlueprintSharedCapture", "CSQLite"]
    ),
    .executableTarget(
      name: "BlueprintApp",
      dependencies: [
        "BlueprintDomain", "BlueprintAudit", "BlueprintPersistence", "BlueprintSharedCapture",
      ],
      swiftSettings: [
        .define("BLUEPRINT_DEBUG", .when(configuration: .debug)),
        .define("BLUEPRINT_RELEASE", .when(configuration: .release)),
      ]
    ),
    .testTarget(
      name: "BlueprintDomainTests",
      dependencies: ["BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintAuditTests",
      dependencies: ["BlueprintAudit", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintSharedCaptureTests",
      dependencies: ["BlueprintSharedCapture"]
    ),
    .testTarget(
      name: "BlueprintPersistenceTests",
      dependencies: ["BlueprintPersistence", "BlueprintDomain", "BlueprintAudit"]
    ),
  ]
)
