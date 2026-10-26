// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFTextEditor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PDFTextEditor",
            path: "Sources/PDFTextEditor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
