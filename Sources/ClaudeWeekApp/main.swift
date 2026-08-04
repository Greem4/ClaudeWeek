import AppKit
import ClaudeWeekCore

// LSUIElement в Info.plist убирает иконку из Dock у собранного бандла;
// setActivationPolicy делает то же самое при запуске бинаря напрямую.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = StatusItemController()
app.run()
