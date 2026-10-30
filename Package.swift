// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VChatNative",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VChatCore", targets: ["VChatCore"]), .library(name: "VChatRendering", targets: ["VChatRendering"]), .executable(name: "VChatMac", targets: ["VChatApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", exact: "5.21.3")
    ],
    targets: [
        .target(name: "VChatCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .target(name: "VChatRendering", dependencies: ["VChatCore", .product(name: "Markdown", package: "swift-markdown"), .product(name: "SwiftMath", package: "SwiftMath"), .product(name: "Highlighter", package: "HighlighterSwift"), .product(name: "SDWebImage", package: "SDWebImage")], resources: [.process("Resources")], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .executableTarget(name: "VChatApp", dependencies: ["VChatCore", "VChatRendering"], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])])
    ],
    swiftLanguageModes: [.v6]
)
