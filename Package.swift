// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SEMIProviderKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SEMIProviderCore", targets: ["SEMIProviderCore"]),
    .library(name: "SEMIProviderRuntime", targets: ["SEMIProviderRuntime"]),
    .library(name: "SEMIProviderApple", targets: ["SEMIProviderApple"]),
  ],
  targets: [
    .target(name: "SEMIProviderCore"),
    .target(
      name: "SEMIProviderRuntime",
      dependencies: ["SEMIProviderCore"]
    ),
    .target(
      name: "SEMIProviderApple",
      dependencies: ["SEMIProviderCore"]
    ),
    .testTarget(
      name: "SEMIProviderCoreTests",
      dependencies: ["SEMIProviderCore"]
    ),
    .testTarget(
      name: "SEMIProviderRuntimeTests",
      dependencies: ["SEMIProviderCore", "SEMIProviderRuntime"]
    ),
    .testTarget(
      name: "SEMIProviderAppleTests",
      dependencies: ["SEMIProviderCore", "SEMIProviderApple"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
