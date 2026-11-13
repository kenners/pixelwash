// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pixelwash",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PixelwashCore", targets: ["PixelwashCore"]),
        .executable(name: "pixelwash", targets: ["pixelwash"]),
        .executable(name: "PixelwashApp", targets: ["PixelwashApp"]),
    ],
    dependencies: [
        // Pinned exactly: the Containerization API changes between releases.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "PixelwashCore",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "pixelwash",
            dependencies: [
                "PixelwashCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "PixelwashApp", dependencies: ["PixelwashCore"]),
        .testTarget(
            name: "PixelwashCoreTests",
            dependencies: ["PixelwashCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
