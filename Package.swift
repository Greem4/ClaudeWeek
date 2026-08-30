// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeWeek",
    platforms: [.macOS(.v14)],
    targets: [
        // Ядро — без единого импорта UI, чтобы расчёты гонялись тестами
        // без запуска приложения.
        .target(name: "ClaudeWeekCore"),

        .executableTarget(
            name: "ClaudeWeekApp",
            dependencies: ["ClaudeWeekCore"],
            resources: [.process("Assets")]
        ),

        // XCTest и swift-testing без Xcode недоступны, поэтому проверки —
        // отдельный исполняемый таргет: `swift run ClaudeWeekTests`.
        .executableTarget(
            name: "ClaudeWeekTests",
            dependencies: ["ClaudeWeekCore"]
        ),
    ]
)
