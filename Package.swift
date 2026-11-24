// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Threadwork",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Threadwork")],
    swiftLanguageModes: [.v5]
)
