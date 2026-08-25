// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quagmire",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "Quagmire", targets: ["Quagmire"]),
        .library(name: "QuagmireExtras", targets: ["QuagmireExtras"])
    ],
    dependencies: [
        .package(url: "https://github.com/danielsaidi/EmojiKit.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "Quagmire",
            dependencies: [
                .product(name: "EmojiKit", package: "EmojiKit")
            ],
            resources: [
                .process("Resources/Sounds"),
                .process("Resources/EmojiAnnotations")
            ]
        ),
        .target(
            name: "QuagmireExtras",
            dependencies: ["Quagmire"]
        ),
        .testTarget(
            name: "QuagmireTests",
            dependencies: ["Quagmire"]
        ),
        .testTarget(
            name: "QuagmirePublicAPITests",
            dependencies: ["Quagmire"]
        ),
        .testTarget(
            name: "QuagmireExtrasTests",
            dependencies: ["QuagmireExtras", "Quagmire"]
        ),
        .testTarget(
            name: "QuagmireExtrasPublicAPITests",
            dependencies: ["QuagmireExtras", "Quagmire"]
        )
    ],
    swiftLanguageModes: [.v6]
)
