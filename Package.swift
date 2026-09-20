// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CatCalendarLayer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CatCore", targets: ["CatCore"]),
        .library(name: "CatPlatform", targets: ["CatPlatform"])
    ],
    targets: [
        // Apple フレームワークに依存しないコア。Linux 上で swift test できる。
        .target(
            name: "CatCore",
            path: "Sources/CatCore"
        ),
        // Apple 依存のアダプタ。全ソースが #if canImport(EventKit) で囲まれているため
        // Linux 上では中身が空になり、ビルドだけは通る。
        .target(
            name: "CatPlatform",
            dependencies: ["CatCore"],
            path: "Sources/CatPlatform"
        ),
        // CatPlatform には依存させない（Linux でテストを走らせるため）。
        .testTarget(
            name: "CatCoreTests",
            dependencies: ["CatCore"],
            path: "Tests",
            sources: ["CatCoreTests", "Mocks"]
        )
    ]
)
