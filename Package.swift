// swift-tools-version:5.9
import PackageDescription

// libzest-core.a is produced by `zig build core` into ./zig-out/lib.
// swift build runs from the repo root, so this -L path is relative to root.
let zigLibDir = "zig-out/lib"

let package = Package(
    name: "Zest",
    platforms: [.macOS(.v14)],
    targets: [
        // C module exposing zest_core.h (header-only; impl is the Zig static lib).
        .target(name: "CZestCore"),

        .executableTarget(
            name: "Zest",
            dependencies: ["CZestCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(zigLibDir)", "-lzest-core"]),
                .linkedLibrary("c"),
            ]
        ),

        .testTarget(
            name: "ZestTests",
            dependencies: ["Zest", "CZestCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(zigLibDir)", "-lzest-core"]),
            ]
        ),
    ]
)
