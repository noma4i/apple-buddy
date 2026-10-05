// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "notes-buddy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "nb", targets: ["notes-buddy"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NotesNative", linkerSettings: [.linkedFramework("CoreData"), .linkedFramework("AppKit"), .linkedFramework("PDFKit"), .linkedFramework("Vision"), .linkedFramework("UniformTypeIdentifiers")]),
        .executableTarget(
            name: "notes-buddy",
            dependencies: ["NotesNative", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "NotesBuddyTests", dependencies: ["notes-buddy", "NotesNative"]),
    ]
)
