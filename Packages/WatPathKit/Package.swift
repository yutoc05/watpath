// swift-tools-version: 6.2
import PackageDescription

// One package, one target per module (docs/PLAN.md §4.4). These modules only
// use Foundation, so their tests also run on Linux CI.
let package = Package(
    name: "WatPathKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CampusGeo", targets: ["CampusGeo"]),
        .library(name: "CampusModel", targets: ["CampusModel"]),
        .library(name: "CampusSearch", targets: ["CampusSearch"]),
        .library(name: "Routing", targets: ["Routing"]),
    ],
    targets: [
        .target(name: "CampusGeo"),
        .target(name: "CampusModel", dependencies: ["CampusGeo"]),
        .target(name: "CampusSearch", dependencies: ["CampusModel"]),
        .target(name: "Routing", dependencies: ["CampusGeo", "CampusModel"]),
        .testTarget(name: "CampusGeoTests", dependencies: ["CampusGeo"]),
        .testTarget(name: "CampusModelTests", dependencies: ["CampusModel"]),
        .testTarget(name: "CampusSearchTests", dependencies: ["CampusSearch"]),
        .testTarget(name: "RoutingTests", dependencies: ["Routing"]),
    ]
)
