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
//   swift scripts/probe-panel.swift --displays
//       То же самое для двух мониторов: по полоске на каждый, поведение окна —
//       как у панели. Отвечает на вопросы, от которых зависит весь показ на
//       втором мониторе: что говорит `isOnActiveSpace` про окно на соседнем
//       мониторе, когда столы переключают на этом, и остаётся ли окно на своём
//       мониторе при показе. Заодно заводит свой значок в строке меню — панель
//       считает место от такого же — и печатает про него два ответа: «по рамке»
//       (так отвечал бы `anchor.screen`) и «по кромке» (так выбирает
//       `DropdownPanel.screen(for:)`). Расходятся они там, где строка меню
//       спрятана полноэкранным окном, см. docs/SPACES.md §7. Значок ClaudeWeek
//       для этого не годится: на macOS 26 окна пунктов строки меню принадлежат
//       «Пункту управления», и по pid приложения в списке окон их нет.
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

func makeProbePanel(
    tag: String, behavior: NSWindow.CollectionBehavior, y: CGFloat,
    on display: NSScreen = NSScreen.main ?? NSScreen.screens[0]
) -> NSPanel {
    let screen = display.frame
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

// MARK: - Режим --displays

/// Номер монитора под точкой (координаты AppKit, снизу вверх).
func display(at point: NSPoint) -> String {
    guard let index = NSScreen.screens.firstIndex(where: { $0.frame.contains(point) })
    else { return "—" }
    return "\(index + 1)"
}

/// Монитор значка так, как его выбирает панель (`DropdownPanel.screen(for:)`):
/// строка меню всегда прижата к верхней кромке своего экрана, поэтому значок
/// принадлежит тому из накрывающих его по горизонтали мониторов, чья верхняя
/// кромка к нему ближе. Ответ расходится с «по рамке» ровно тогда, когда строку
/// меню спрятало полноэкранное окно, а сосед стоит вплотную сверху.
func display(byEdge icon: NSRect) -> String {
    let covering = NSScreen.screens.filter { $0.frame.minX <= icon.midX && icon.midX <= $0.frame.maxX }
    guard let screen = (covering.isEmpty ? NSScreen.screens : covering)
        .min(by: { abs($0.frame.maxY - icon.maxY) < abs($1.frame.maxY - icon.maxY) }),
        let index = NSScreen.screens.firstIndex(of: screen)
    else { return "—" }
    return "\(index + 1)"
}

/// Монитор, который окно считает своим (`NSWindow.screen` — тот, где лежит
/// большая часть окна). «нет» у снятого с экрана окна и у окна, не попавшего
/// ни на один экран, — так отвечает и окно значка при спрятанной строке меню.
func display(ofWindow window: NSWindow) -> String {
    guard let screen = window.screen,
          let index = NSScreen.screens.firstIndex(of: screen)
    else { return "нет" }
    return "\(index + 1)"
}

func compareDisplays() -> Never {
    let screens = NSScreen.screens
    guard screens.count > 1 else {
        say("подключён один монитор — сравнивать нечего. Подключите второй и повторите")
        exit(1)
    }

    // По полоске на каждый монитор, поведение окна — как у панели.
    let strips = screens.enumerated().map { index, screen in
        makeProbePanel(
            tag: "D\(index + 1)  монитор \(index + 1) — поведение панели",
            behavior: [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle],
            y: screen.frame.maxY - 140,
            on: screen
        )
    }
    // Свой значок в строке меню. Чужой отсюда не измерить: на macOS 26 окна
    // пунктов строки меню принадлежат «Пункту управления», а не приложению,
    // и по pid ClaudeWeek в списке окон не находятся вовсе. Свой ведёт себя
    // так же — он в той же строке меню и прячется вместе с ней, а рамку и
    // экран отдаёт прямо, без списка окон.
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "◱"

    func status() -> String {
        var parts = ["активный стол:\(activeSpace())"]
        if let icon = item.button?.window {
            let frame = icon.frame
            parts.append(String(format: "значок: по рамке %@ по кромке %@ x%.0f y%.0f…%.0f",
                                display(ofWindow: icon), display(byEdge: frame),
                                frame.midX, frame.minY, frame.maxY))
        }
        for (index, strip) in strips.enumerated() {
            parts.append("D\(index + 1): монитор=\(display(ofWindow: strip))"
                + " на своём столе=\(strip.isOnActiveSpace ? "да " : "НЕТ")"
                + " столы=\(spaces(ofWindow: strip.windowNumber))")
        }
        return parts.joined(separator: " | ")
    }

    say("по полоске на каждом мониторе, 70 секунд. Переключайте столы на обоих"
        + " мониторах и щёлкайте по значку — на том мониторе и на соседнем")
    say("у своего значка смотрите на y и на выбор монитора: по x он стоит там,"
        + " где нашлось место, а не влезший в строку меню уезжает за левый край")

    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
        let point = NSEvent.mouseLocation
        say(String(format: "%@ клик x%.0f y%.0f монитор %@ | %@",
                   stamp(), point.x, point.y, display(at: point), status()))
        // Значок переезжает вслед за строкой меню, и вопрос в том, успевает ли
        // он к обработке щелчка: панель считает место от его рамки.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            say("\(stamp()) через 0.3 с | \(status())")
        }
    }

    var previous = ""
    var ticks = 0
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        ticks += 1
        let line = status()
        if line != previous {
            previous = line
            say("\(stamp()) \(line)")
        }
        // Раз в четыре секунды показываем заново — так показывается панель.
        // Здесь и видно, остаётся окно на своём мониторе или уезжает.
        if ticks.isMultiple(of: 8) {
            for strip in strips {
                strip.orderOut(nil)
                strip.orderFrontRegardless()
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
case "--displays": compareDisplays()
case let other?:
    say("не знаю такого режима: \(other). Есть --watch, --behaviors и --displays")
    exit(2)
}
