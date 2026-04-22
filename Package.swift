// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NCursesUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NCursesUI", targets: ["NCursesUI"]),
        .library(name: "Cncurses", targets: ["Cncurses"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(path: "../../localdev/Lattice"),
    ],
    targets: [
        .target(
            name: "Cncurses",
            linkerSettings: [.linkedLibrary("ncurses")]
        ),
        .target(
            name: "NCursesUI",
            dependencies: [
                "Cncurses",
                .product(name: "Logging", package: "swift-log"),
                "Lattice",
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "NCursesUITests",
            dependencies: ["NCursesUI"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)
