// swift-tools-version:5.9
import PackageDescription

// libzest-core.a is produced by `zig build core` into ./zig-out/lib.
// swift build runs from the repo root, so this -L path is relative to root.
let zigLibDir = "zig-out/lib"

let package = Package(
    name: "Zest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
            exact: "0.5.3"
        ),
    ],
    targets: [
        // C module exposing zest_core.h (header-only; impl is the Zig static lib).
        .target(name: "CZestCore"),

        .target(
            name: "TreeSitterSema",
            path: "Vendor/TreeSitterSema",
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [.copy("queries")],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),

        .executableTarget(
            name: "Zest",
            dependencies: [
                "CZestCore",
                "TreeSitterSema",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
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
