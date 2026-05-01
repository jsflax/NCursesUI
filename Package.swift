// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NCursesUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NCursesUI", targets: ["NCursesUI"]),
        .library(name: "Cncurses", targets: ["Cncurses"]),
        .library(name: "NCUITestProtocol", targets: ["NCUITestProtocol"]),
        .library(name: "NCUITest", targets: ["NCUITest"]),
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
            name: "NCUITestProtocol"
        ),
        .target(
            name: "NCursesUI",
            dependencies: [
                "Cncurses",
                "NCUITestProtocol",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "NCUITest",
            dependencies: ["NCUITestProtocol"]
        ),
        .testTarget(
            name: "NCursesUITests",
            dependencies: ["NCursesUI"]
        ),
        .testTarget(
            name: "NCUITestSelfTests",
            dependencies: ["NCUITest", "WidgetsDemo"]
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
