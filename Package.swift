// swift-tools-version: 6.0

// DMCNKit is the protocol and client core every Apple app target shares: the generated core
// schema, the message crypto, record verification, and the web-host API client. It has no UI
// and no platform-specific storage, so it builds and tests on Linux as well as on Apple
// platforms; the apps under App/ are thin targets on top of it. DMCNKitSamples is an in-memory
// mailbox for previews, debug builds and tests.

import PackageDescription

let package = Package(
    name: "DMCNKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "DMCNKit", targets: ["DMCNKit"]),
        .library(name: "DMCNKitSamples", targets: ["DMCNKitSamples"]),
    ],
    dependencies: [
        // Apache 2.0. The runtime for the code generated from proto/ by protoc-gen-swift.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        // Apache 2.0. CryptoKit's API; on Apple platforms it re-exports CryptoKit itself, so the
        // kit compiles against one API everywhere and tests run on Linux CI.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "DMCNKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "DMCNKitSamples", dependencies: ["DMCNKit"]),
        // The app's state, which has no SwiftUI in it, built here as well so it can be tested
        // anywhere the kit can. The Xcode project compiles the same sources into the app.
        .target(
            name: "AppState",
            dependencies: ["DMCNKit", "DMCNKitSamples"],
            path: "App/AppState"
        ),
        .testTarget(
            name: "DMCNKitTests",
            dependencies: ["DMCNKit", "DMCNKitSamples"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AppStateTests",
            dependencies: ["AppState", "DMCNKit", "DMCNKitSamples"]
        ),
    ]
)
