import AppKit
import ClaudeWeekCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print(CLI.usage)
    exit(0)
}

if arguments.contains("--verbose") {
    Log.minimumLevel = .debug
}

var config = ConfigStore.load()
if let raw = arguments.first(where: { $0.hasPrefix("--provider=") })?
    .split(separator: "=", maxSplits: 1).last,
   let choice = ProviderPreference(rawValue: String(raw)) {
    config.provider = choice
}

if arguments.contains("--json") {
    exit(await CLI.run(config: config))
}

if let index = arguments.firstIndex(of: "--screenshot") {
    let directory = arguments.count > index + 1
        ? URL(fileURLWithPath: arguments[index + 1])
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    exit(await Screenshot.render(into: directory, config: config))
}

// LSUIElement в Info.plist убирает иконку из Dock у собранного бандла;
// setActivationPolicy делает то же самое при запуске бинаря напрямую.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = StatusItemController()
app.run()
