#!/usr/bin/env swift

// Разведка панели на рабочих столах: чем ловится «панель не открывается».
//
// Два режима:
//
//   swift scripts/probe-panel.swift --watch
//       Смотрит со стороны на работающий ClaudeWeek: когда окно панели
//       появляется и пропадает, где встаёт, на каких столах лежит, и какие
//       клики этому предшествовали. Отвечает на вопрос «панель погасла сама
//       или это был мой клик» — он же главный при разборе таких жалоб.
//
//   swift scripts/probe-panel.swift --behaviors
//       Показывает две полоски у верхнего края экрана — окно на одном столе
//       (`.moveToActiveSpace`, как в панели) и окно на всех столах
//       (`.canJoinAllSpaces`), — и печатает, что каждое отвечает про
//       `isOnActiveSpace`. Нужен, если снова захочется поменять
//       `collectionBehavior` у `MenuPanel`: проверять такое чтением кода
//       бесполезно, см. docs/SPACES.md.
//
// В обоих режимах пройдитесь по рабочим столам — свайпом или ⌃→. Разбор
// собранного и что с ним делать: docs/SPACES.md.
//
// Номера рабочих столов берутся из SkyLight (приватный API). Это отладочный
// скрипт, в приложение он не входит и в сборку не попадает; в самом
// ClaudeWeek приватных вызовов нет.

import AppKit

// MARK: - Номера столов

typealias CGSConnectionID = UInt32
private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
private typealias MainConnFn = @convention(c) () -> CGSConnectionID
private typealias ActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64
private typealias SpacesForWindowsFn =
    @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?

private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let sky, let pointer = dlsym(sky, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
}

private let connection = symbol("CGSMainConnectionID", as: MainConnFn.self)?() ?? 0
private let activeSpaceFn = symbol("CGSGetActiveSpace", as: ActiveSpaceFn.self)
private let spacesForWindowsFn = symbol("CGSCopySpacesForWindows", as: SpacesForWindowsFn.self)

func activeSpace() -> String { activeSpaceFn.map { String($0(connection)) } ?? "?" }

func spaces(ofWindow number: Int) -> String {
    guard let spacesForWindowsFn,
          let raw = spacesForWindowsFn(connection, 7, [NSNumber(value: number)] as CFArray)?
              .takeRetainedValue() as? [NSNumber]
    else { return "—" }
    return raw.map(\.stringValue).sorted().joined(separator: ",")
}

let clock = Date.FormatStyle(date: .omitted, time: .standard).secondFraction(.fractional(2))
func stamp() -> String { Date().formatted(clock) }

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

// MARK: - Режим --watch

/// Слой окна панели: `NSWindow.Level.popUpMenu`. По нему панель отличается от
/// окна настроек (слой 0) и от подсказки.
let panelLayer = 101

func watch() -> Never {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "ClaudeWeek" || $0.executableURL?.lastPathComponent == "ClaudeWeek"
    }) else {
        say("ClaudeWeek не запущен — запустите приложение и повторите")
        exit(1)
    }
    let pid = app.processIdentifier
    say("смотрю за ClaudeWeek (pid \(pid)). Щёлкайте по значку и ходите по столам, 3 минуты")

    // Слежка за мышью разрешения не требует — в отличие от клавиатуры.
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
        let point = NSEvent.mouseLocation
        let kind = event.type == .rightMouseDown ? "правой" : "левой"
        say(String(format: "%@ клик %@ в x%.0f y%.0f", stamp(), kind, point.x, point.y))
    }

    var wasVisible: Bool?
    var ticks = 0
    let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
        ticks += 1
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              let panel = list.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                      && ($0[kCGWindowLayer as String] as? Int) == panelLayer
              })
        else { return }

        let visible = (panel[kCGWindowIsOnscreen as String] as? Bool) ?? false
        guard visible != wasVisible else { return }
        wasVisible = visible

        let number = panel[kCGWindowNumber as String] as? Int ?? -1
        let bounds = panel[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let rect = String(format: "x%.0f y%.0f w%.0f h%.0f",
                          bounds["X"] ?? 0, bounds["Y"] ?? 0,
                          bounds["Width"] ?? 0, bounds["Height"] ?? 0)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        say("\(stamp()) панель \(visible ? "появилась" : "пропала  ") \(rect)"
            + " активный стол:\(activeSpace()) впереди:\(front.prefix(14))"
            + " столы окна:\(spaces(ofWindow: number))")

        if ticks >= 720 { exit(0) }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

// MARK: - Режим --behaviors

func makeProbePanel(tag: String, behavior: NSWindow.CollectionBehavior, y: CGFloat) -> NSPanel {
    let screen = NSScreen.main!.frame
    let panel = NSPanel(
        contentRect: NSRect(x: screen.midX - 200, y: y, width: 400, height: 40),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = behavior
    panel.isOpaque = false
    panel.backgroundColor = NSColor.black.withAlphaComponent(0.9)
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true

    let label = NSTextField(labelWithString: tag)
    label.textColor = .white
    label.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
    label.frame = NSRect(x: 12, y: 10, width: 376, height: 20)
    panel.contentView?.addSubview(label)
    panel.orderFrontRegardless()
    return panel
}

func compareBehaviors() -> Never {
    let top = NSScreen.main!.frame.maxY
    let single = makeProbePanel(
        tag: "M  .moveToActiveSpace — как в панели",
        behavior: [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle],
        y: top - 140
    )
    let everywhere = makeProbePanel(
        tag: "C  .canJoinAllSpaces — окно на всех столах",
        behavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle],
        y: top - 190
    )
    say("две полоски у верхнего края, 70 секунд. Ходите по столам, щёлкать не нужно")

    var previous = ""
    var ticks = 0
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        ticks += 1
        let line = "активный стол:\(activeSpace())"
            + " | M: на своём столе=\(single.isOnActiveSpace ? "да " : "НЕТ")"
            + " столы=\(spaces(ofWindow: single.windowNumber))"
            + " | C: на своём столе=\(everywhere.isOnActiveSpace ? "да " : "НЕТ")"
            + " столы=\(spaces(ofWindow: everywhere.windowNumber))"
        if line != previous {
            previous = line
            say("\(stamp()) \(line)")
        }
        // Раз в четыре секунды показываем заново — так панель ведёт себя по
        // щелчку, и видно, переезжает ли окно на текущий стол.
        if ticks.isMultiple(of: 8) {
            for panel in [single, everywhere] {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        if ticks >= 140 { exit(0) }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

// MARK: - Запуск

switch CommandLine.arguments.dropFirst().first {
case "--watch", nil: watch()
case "--behaviors": compareBehaviors()
case let other?:
    say("не знаю такого режима: \(other). Есть --watch и --behaviors")
    exit(2)
}
