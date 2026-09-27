// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        // Sift's Kit. Named FileKit rather than SiftKit (the one exception to the MacHUD naming
        // convention) because Stash depends on it, and imports it, by that name.
        .library(name: "FileKit", targets: ["FileKit"]),
        .executable(name: "Sift", targets: ["Sift"]),
        // Installed as Contents/Helpers/sift: a distinct product name because Sift and sift
        // would collide on a case-insensitive volume.
        .executable(name: "SiftCLI", targets: ["SiftCLI"]),
    ],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to ~/dev/sift.
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure file-management core: scanning, watching, actions, undo journal, rules,
        // rename templates, tags, search. No UI.
        .target(
            name: "FileKit",
            path: "Sources/FileKit"
        ),
        .executableTarget(
            name: "Sift",
            dependencies: ["FileKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/Sift",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `sift <command> [key=value ...]`: a thin client for Sift's MacHUD control socket.
        .executableTarget(
            name: "SiftCLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/SiftCLI"
        ),
        .testTarget(
            name: "FileKitTests",
            dependencies: ["FileKit"],
            path: "Tests/FileKitTests"
        ),
        // Host logic in the app target (e.g. where `panel mode parked` parks) and the shipped
        // manifest, settings schema and Info.plist.
        .testTarget(
            name: "SiftTests",
            dependencies: ["Sift", "FileKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/SiftTests"
        ),
    ]
)
