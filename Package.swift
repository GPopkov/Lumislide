// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumislide",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Lumislide", targets: ["SlideStoryApp"]),
        .library(name: "SlideStoryModel", targets: ["SlideStoryModel"]),
        .library(name: "SlideStoryRenderer", targets: ["SlideStoryRenderer"]),
    ],
    targets: [
        // MARK: - Модель проекта (без зависимостей от UI и рендеринга)
        .target(
            name: "SlideStoryModel",
            path: "Sources/SlideStoryModel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - Рендер-пайплайн (AVFoundation / CoreImage / Metal / Vision)
        .target(
            name: "SlideStoryRenderer",
            dependencies: ["SlideStoryModel"],
            path: "Sources/SlideStoryRenderer",
            resources: [
                .process("Resources/Transitions.metal")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - UI-слой (SwiftUI + AppKit)
        .executableTarget(
            name: "SlideStoryApp",
            dependencies: ["SlideStoryModel", "SlideStoryRenderer"],
            path: "Sources/SlideStoryApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - Тесты
        .testTarget(
            name: "SlideStoryModelTests",
            dependencies: ["SlideStoryModel"],
            path: "Tests/SlideStoryModelTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SlideStoryRendererTests",
            dependencies: ["SlideStoryRenderer", "SlideStoryModel"],
            path: "Tests/SlideStoryRendererTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SlideStoryAppTests",
            dependencies: ["SlideStoryApp", "SlideStoryModel", "SlideStoryRenderer"],
            path: "Tests/SlideStoryAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
