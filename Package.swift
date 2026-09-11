// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ouchikaeru",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "TransitCore", targets: ["TransitCore"])],
    targets: [.target(name: "TransitCore"), .testTarget(name: "TransitCoreTests", dependencies: ["TransitCore"])],
    swiftLanguageModes: [.v5]
)
