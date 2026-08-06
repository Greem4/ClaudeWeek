import AppKit
import ClaudeWeekCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print(CLI.usage)
    exit(0)
}

// Опечатку в флаге ловим до всего остального: иначе `--jsonn` поднял бы
// строку меню, а человек ждал бы вывода в терминал.
if let unknown = arguments.first(where: { $0.hasPrefix("-") && !CLI.isKnown($0) }) {
    exit(CLI.complain("незнакомый аргумент «\(unknown)»"))
}

if arguments.contains("--verbose") {
    Log.minimumLevel = .debug
}

let configURL = arguments.first(where: { $0.hasPrefix("--config=") })
    .map { URL(fileURLWithPath: String($0.dropFirst("--config=".count))) }
    ?? ConfigStore.fileURL

var config = ConfigStore.load(from: configURL)
if let raw = arguments.first(where: { $0.hasPrefix("--provider=") })?
    .dropFirst("--provider=".count) {
    guard let choice = ProviderPreference(rawValue: String(raw)) else {
        exit(CLI.complain("неизвестный источник «\(raw)»: бывают official, local и auto"))
    }
    config.provider = choice
}

if let raw = arguments.first(where: { $0.hasPrefix("--calibrate=") })?
    .dropFirst("--calibrate=".count) {
    guard let percent = Double(raw) else {
        exit(CLI.complain("«\(raw)» — не число: --calibrate ждёт процент из /usage"))
    }
    exit(await CLI.calibrate(percent: percent, config: config, configURL: configURL))
}

if arguments.contains("--json") {
    exit(await CLI.run(config: config))
}

if arguments.contains("--icon") {
    exit(AppIcon.render(into: CLI.directory(after: "--icon", in: arguments)))
}

if arguments.contains("--screenshot") {
    // Без await: `Screenshot` изолирован главным актором, а код верхнего
    // уровня и так на нём.
    exit(Screenshot.render(
        into: CLI.directory(after: "--screenshot", in: arguments),
        config: config
    ))
}

// LSUIElement в Info.plist убирает иконку из Dock у собранного бандла;
// setActivationPolicy делает то же самое при запуске бинаря напрямую.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = StatusItemController(config: config, configURL: configURL)
app.run()
