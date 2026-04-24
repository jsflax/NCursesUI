// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NCursesUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NCursesUI", targets: ["NCursesUI"]),
        .library(name: "Cncurses", targets: ["Cncurses"]),
        .executable(name: "WidgetsDemo", targets: ["WidgetsDemo"]),
        .executable(name: "OverlayTaskRepro", targets: ["OverlayTaskRepro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "Cncurses",
            linkerSettings: [
                .linkedLibrary("ncurses"),
                .linkedLibrary("panel"),
            ]
        ),
        .target(
            name: "NCursesUI",
            dependencies: [
                "Cncurses",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "NCursesUITests",
            dependencies: ["NCursesUI"]
        ),
        .executableTarget(
            name: "WidgetsDemo",
            dependencies: ["NCursesUI"],
            path: "Examples/WidgetsDemo"
        ),
        .executableTarget(
            name: "OverlayTaskRepro",
            dependencies: ["NCursesUI"],
            path: "Examples/OverlayTaskRepro"
        ),
    ]
)
