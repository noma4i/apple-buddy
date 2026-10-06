// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apple-buddy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "abdy", targets: ["apple-buddy"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "NotesNative", linkerSettings: [.linkedFramework("CoreData"), .linkedFramework("AppKit"), .linkedFramework("PDFKit"), .linkedFramework("Vision"), .linkedFramework("UniformTypeIdentifiers")]),
        .target(name: "RemindersNative"),
        .executableTarget(
            name: "apple-buddy",
            dependencies: ["NotesNative", "RemindersNative", .product(name: "ArgumentParser", package: "swift-argument-parser"), .product(name: "MCP", package: "swift-sdk")],
            linkerSettings: [.linkedFramework("EventKit"), .linkedFramework("ImageIO"), .linkedFramework("UniformTypeIdentifiers")]
        ),
        .testTarget(name: "AppleBuddyTests", dependencies: ["apple-buddy", "NotesNative"]),
    ]
)
