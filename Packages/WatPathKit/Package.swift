// swift-tools-version: 6.2
import PackageDescription

// One package, one target per module (docs/PLAN.md §4.4). CampusGeo and
// CampusModel only use Foundation so their tests also run on Linux CI.
let package = Package(
    name: "WatPathKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CampusGeo", targets: ["CampusGeo"]),
        .library(name: "CampusModel", targets: ["CampusModel"]),
    ],
    targets: [
        .target(name: "CampusGeo"),
        .target(name: "CampusModel", dependencies: ["CampusGeo"]),
        .testTarget(name: "CampusGeoTests", dependencies: ["CampusGeo"]),
        .testTarget(name: "CampusModelTests", dependencies: ["CampusModel"]),
    ]
)
