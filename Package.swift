// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VChatNative",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VChatCore", targets: ["VChatCore"]), .executable(name: "VChatMac", targets: ["VChatApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.0.0")],
    targets: [
        .target(name: "VChatCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .executableTarget(name: "VChatApp", dependencies: ["VChatCore"], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])])
    ],
    swiftLanguageModes: [.v6]
)
