// swift-tools-version:5.9
// Satpane Enhance for iOS: sharper Satpane satellite imagery close up, made on the device.
import PackageDescription

let package = Package(
  name: "SatpaneEnhance",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "SatpaneEnhance", targets: ["SatpaneEnhance"]),
  ],
  // No dependencies: the model runs with Core ML, which is part of iOS.
  targets: [
    // The planning logic on its own, so it can be tested anywhere.
    .target(name: "SatpaneEnhancePlan", path: "ios/Sources/SatpaneEnhancePlan"),
    .target(
      name: "SatpaneEnhance",
      dependencies: ["SatpaneEnhancePlan"],
      path: "ios/Sources/SatpaneEnhance"
    ),
    .testTarget(name: "SatpaneEnhancePlanTests", dependencies: ["SatpaneEnhancePlan"], path: "ios/Tests/SatpaneEnhancePlanTests"),
  ]
)
