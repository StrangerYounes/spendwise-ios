// swift-tools-version:5.9
import PackageDescription

// Everything that is not UI: the database (the same SQLite schema, queries and sync triggers as the
// Android app's Room database), lists, items and the item library, backups, money parsing, the AI
// requests and answers, spending analysis and the Firebase-free half of sync. Foundation and SQLite
// only, so it builds and tests on Linux as well as on Apple platforms.
let package = Package(
    name: "SpendWiseCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SpendWiseCore", targets: ["SpendWiseCore"]),
    ],
    targets: [
        // Apple platforms import the SDK's SQLite3 module; Linux links the system's libsqlite3.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "SpendWiseCore", dependencies: [
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]),
        .testTarget(
            name: "SpendWiseCoreTests",
            dependencies: ["SpendWiseCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
