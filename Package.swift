// swift-tools-version: 6.2
import PackageDescription

// PixKit — the client for a shared photo space between two friends, as a
// self-contained SPM: Connect transport for the metadata, plain HTTP for the
// bytes (resumable uploads, Range downloads), a cache, and the UI. Talks to
// mvPix. A host app (or PixLab) supplies identity + a token.
//
// Mirrors CalendarKit's shape: the kit never owns login — the host injects a
// `tokenProvider`. Swift 6 strict concurrency from line one.
let package = Package(
    name: "PixKit",
    platforms: [.iOS(.v26)], // iOS-only
    products: [
        .library(name: "PixKit", targets: ["PixKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "PixKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PixKitTests",
            dependencies: ["PixKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
