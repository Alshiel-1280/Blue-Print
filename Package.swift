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
    .library(name: "BlueprintDocuments", targets: ["BlueprintDocuments"]),
    .library(name: "BlueprintImports", targets: ["BlueprintImports"]),
    .library(name: "BlueprintBilling", targets: ["BlueprintBilling"]),
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
      name: "BlueprintDocuments",
      dependencies: ["BlueprintDomain"]
    ),
    .target(
      name: "BlueprintImports",
      dependencies: ["BlueprintDomain", "BlueprintDocuments"]
    ),
    .target(
      name: "BlueprintBilling",
      dependencies: ["BlueprintDomain", "BlueprintDocuments"]
    ),
    .target(
      name: "BlueprintPersistence",
      dependencies: [
        "BlueprintDomain", "BlueprintAudit", "BlueprintSharedCapture", "BlueprintDocuments",
        "BlueprintImports", "BlueprintBilling", "CSQLite",
      ]
    ),
    .executableTarget(
      name: "BlueprintApp",
      dependencies: [
        "BlueprintDomain", "BlueprintAudit", "BlueprintPersistence", "BlueprintSharedCapture",
        "BlueprintDocuments", "BlueprintImports", "BlueprintBilling",
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
      name: "BlueprintDocumentsTests",
      dependencies: ["BlueprintDocuments", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintImportsTests",
      dependencies: ["BlueprintImports", "BlueprintDocuments", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintBillingTests",
      dependencies: ["BlueprintBilling", "BlueprintDocuments", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintPersistenceTests",
      dependencies: [
        "BlueprintPersistence", "BlueprintDomain", "BlueprintAudit", "BlueprintDocuments",
        "BlueprintImports", "BlueprintBilling",
      ]
    ),
  ]
)
