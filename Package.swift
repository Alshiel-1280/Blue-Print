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
    .library(name: "BlueprintClosing", targets: ["BlueprintClosing"]),
    .library(name: "BlueprintFiling", targets: ["BlueprintFiling"]),
    .library(name: "BlueprintTax", targets: ["BlueprintTax"]),
    .library(name: "BlueprintETax", targets: ["BlueprintETax"]),
    .library(name: "BlueprintTransfer", targets: ["BlueprintTransfer"]),
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
      name: "BlueprintClosing",
      dependencies: ["BlueprintDomain", "BlueprintBilling"]
    ),
    .target(
      name: "BlueprintFiling",
      dependencies: ["BlueprintDomain", "BlueprintDocuments", "BlueprintClosing"]
    ),
    .target(
      name: "BlueprintTax",
      dependencies: ["BlueprintDomain", "BlueprintClosing", "BlueprintFiling"]
    ),
    .target(
      name: "BlueprintETax",
      dependencies: ["BlueprintDomain", "BlueprintFiling", "BlueprintTax"]
    ),
    .target(
      name: "BlueprintTransfer",
      dependencies: ["BlueprintDomain"]
    ),
    .target(
      name: "BlueprintPersistence",
      dependencies: [
        "BlueprintDomain", "BlueprintAudit", "BlueprintSharedCapture", "BlueprintDocuments",
        "BlueprintImports", "BlueprintBilling", "BlueprintClosing", "BlueprintFiling",
        "BlueprintTax",
        "BlueprintETax", "BlueprintTransfer", "CSQLite",
      ]
    ),
    .executableTarget(
      name: "BlueprintApp",
      dependencies: [
        "BlueprintDomain", "BlueprintAudit", "BlueprintPersistence", "BlueprintSharedCapture",
        "BlueprintDocuments", "BlueprintImports", "BlueprintBilling", "BlueprintClosing",
        "BlueprintFiling", "BlueprintTax", "BlueprintETax", "BlueprintTransfer",
      ],
      swiftSettings: [
        .define("BLUEPRINT_DEBUG", .when(configuration: .debug)),
        .define("BLUEPRINT_RELEASE", .when(configuration: .release)),
      ],
      linkerSettings: [.linkedFramework("Security")]
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
      name: "BlueprintClosingTests",
      dependencies: ["BlueprintClosing", "BlueprintBilling", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintFilingTests",
      dependencies: ["BlueprintFiling", "BlueprintClosing", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintTaxTests",
      dependencies: ["BlueprintTax", "BlueprintClosing", "BlueprintFiling", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintETaxTests",
      dependencies: ["BlueprintETax", "BlueprintTax", "BlueprintFiling", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintTransferTests",
      dependencies: ["BlueprintTransfer", "BlueprintDomain"]
    ),
    .testTarget(
      name: "BlueprintPersistenceTests",
      dependencies: [
        "BlueprintPersistence", "BlueprintDomain", "BlueprintAudit", "BlueprintDocuments",
        "BlueprintImports", "BlueprintBilling", "BlueprintClosing", "BlueprintFiling",
        "BlueprintTax",
        "BlueprintETax", "BlueprintTransfer",
      ]
    ),
  ]
)
