import AppKit
import SwiftUI
import Observation
import ClaudeWeekCore

/// Состояние окна настроек. Правки применяются сразу — «Сохранить» здесь нет:
/// панель и строка меню перерисовываются, пока крутишь ползунок, иначе
/// подбирать прозрачность и тему пришлось бы вслепую.
@MainActor
@Observable
final class SettingsModel {
    var config: Config {
        didSet {
            guard !isAdopting, config != oldValue else { return }
            apply(config)
        }
    }

    /// Конфиг пришёл снаружи, а не из ползунка: гнать его обратно через
    /// `apply` незачем — он уже применён и уже лежит на диске.
    private var isAdopting = false

    /// Итог последней проверки токена: текст и удача/неудача.
    var checkResult: (text: String, ok: Bool)?
    var isChecking = false
    /// Бюджет недели, подобранный программой по официальному проценту. Живёт
    /// в кеше, а не в конфиге, поэтому вкладка «О программе» читает его
    /// отдельно — иначе она показывала бы «не подобран» даже после калибровки.
    private(set) var pickedBudget: Double?
    /// Момент недельного сброса, названный сервером. Живёт в кеше, а не в
    /// конфиге: настройками его не задать — и именно поэтому его нужно
    /// показать. Человек, искавший в настройках «день сброса», иначе крутит
    /// поля и гадает, почему неделя начинается не тогда, когда он поставил.
    private(set) var officialReset: Date?
    /// Автозапуск тоже мимо конфига: он и есть launchd-агент, и правда о нём
    /// одна — лежит плист или нет.
    private(set) var launchAtLogin = LoginItem.isEnabled

    /// Обновление идёт мимо конфига, и состояние у него общее с панелью и
    /// меню — сюда приходит тот же контроллер, а не его копия.
    let update: UpdateController

    /// Уведомления — по той же причине тот же контроллер: разрешение macOS
    /// живёт вне конфига, и спрашивать его вторым экземпляром бессмысленно.
    let notifications: NotificationController

    private let apply: (Config) -> Void
    private let check: (Config) async -> (String, Bool)

    init(
        config: Config,
        update: UpdateController,
        notifications: NotificationController,
        apply: @escaping (Config) -> Void,
        check: @escaping (Config) async -> (String, Bool)
    ) {
        self.config = config
        self.update = update
        self.notifications = notifications
        self.apply = apply
        self.check = check
        refreshDiagnostics()
    }

    /// Перечитывает то, что живёт вне конфига: подобранный бюджет из кеша и
    /// автозапуск. Зовётся при каждом показе окна — читать файлы на каждую
    /// перерисовку вкладки незачем, а между показами плист мог снести
    /// `uninstall.sh` или рука.
    func refreshDiagnostics() {
        let cache = Store.loadCache()
        pickedBudget = cache?.weeklyBudget
        // Момент из кеша мог остаться в прошлой неделе — проекция вперёд
        // целыми неделями даёт тот, который наступит следующим.
        officialReset = cache?.projectedWindow(at: Date(), config: config)?.end
        launchAtLogin = LoginItem.isEnabled
        // Разрешение на уведомления снимают там же, где выдали, — в системных
        // настройках, мимо этого окна. Спрашиваем систему на каждый показ.
        notifications.refresh()
    }

    /// Состояние возвращаем не из галочки, а из самого агента: включить его
    /// удаётся не всегда, и переключатель, оставшийся стоять после неудачи,
    /// обещал бы автозапуск, которого нет.
    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    /// Принять конфиг, изменившийся мимо этого окна: файл правили руками.
    /// Модель живёт от первого открытия настроек до выхода из приложения, и
    /// без этого второй показ окна выкладывал бы значения, которых в файле
    /// давно нет, — а первый же сдвинутый ползунок затирал бы правку.
    func adopt(_ config: Config) {
        guard config != self.config else { return }
        isAdopting = true
        self.config = config
        isAdopting = false
    }

    /// Подпись бюджета: заданный человеком важнее подобранного программой,
    /// поэтому и показываем, откуда взялось число.
    var budgetNote: String {
        let s = config.strings
        if config.weeklyBudget > 0 {
            let cost = Formatting.cost(config.weeklyBudget, lang: s.lang)
            return s.pick("\(cost) ≈ 100 % · задан вами", "\(cost) ≈ 100 % · set by you")
        }
        if let pickedBudget, pickedBudget > 0 {
            let cost = Formatting.cost(pickedBudget, lang: s.lang)
            return s.pick("\(cost) ≈ 100 % · подобран сам", "\(cost) ≈ 100 % · worked out by the app")
        }
        return s.pick("не подобран", "not worked out yet")
    }

    /// Подсказка под «Началом недели»: настройка двигает только порядок строк
    /// на панели, а сам момент сброса приходит от сервера — тот, что здесь и
    /// показан, в той же зоне, по которой панель считает сутки.
    var weekStartNote: String {
        let s = config.strings
        guard let officialReset else {
            return s.pick(
                "Момент сброса задаёт сервер, а не эта настройка: она двигает только порядок строк на панели.",
                "The reset moment comes from the server, not from this setting: it only shifts the row order."
            )
        }
        let day = Formatting.weekdayShort(officialReset, calendar: config.calendar, lang: s.lang)
        let time = Formatting.clock(officialReset, calendar: config.calendar)
        return s.pick(
            "Сброс задаёт сервер — \(day) \(time) по выбранной зоне. Эта настройка двигает только порядок строк.",
            "The reset comes from the server — \(day) \(time) in the zone picked above. This setting only shifts the row order."
        )
    }

    /// «Показать пример» с вкладки уведомлений: тот же баннер, что придёт
    /// по-настоящему, — по одному на каждый лимит. Идёт мимо конфига:
    /// показанному баннеру нечего сохранять.
    func previewNotification(_ kind: AlertKind) {
        notifications.preview(kind, config: config)
    }

    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        checkResult = nil
        let config = config
        Task { [weak self] in
            let (text, ok) = await (self?.check(config) ?? ("", false))
            self?.checkResult = (text, ok)
            self?.isChecking = false
        }
    }

    /// Вернуть всё к заводскому — кроме калибровки и бюджета: их подбирала
    /// программа по живым данным, и терять их из-за «сбросить внешний вид»
    /// было бы обидно.
    func resetToDefaults() {
        var fresh = Config.default
        fresh.weeklyBudget = config.weeklyBudget
        fresh.calibration = config.calibration
        config = fresh
    }
}

/// Обычное окно приложения: с рамкой, в Mission Control, закрывается по ⌘W.
/// Панель для этого не годится — в ней невозможно ни выделить текст поля,
/// ни оставить настройки открытыми, пока смотришь на строку меню.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    /// Окно на экране — настоящую панель пора показать рядом.
    var onPresent: () -> Void = {}
    /// Окно закрыли или свернули — панель больше держать незачем.
    var onDismiss: () -> Void = {}

    init(model: SettingsModel) {
        self.model = model
    }

    /// Конфиг переписали мимо окна — покажем то, что в файле, а не то, что
    /// окно помнит с прошлого раза.
    func adopt(_ config: Config) { model.adopt(config) }

    /// `obstacle` — рамка живой панели: новое окно ставим так, чтобы её
    /// не накрыть, иначе предпросмотр придётся откапывать мышью.
    func show(avoiding obstacle: NSRect? = nil) {
        model.refreshDiagnostics()
        if let window {
            present(window)
            onPresent()
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = model.config.strings.pick("Настройки ClaudeWeek", "ClaudeWeek Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ClaudeWeekSettings")
        // moveToActiveSpace — чтобы окно приходило на тот стол, с которого его
        // позвали, а не утаскивало экран туда, где его открыли в первый раз.
        // fullScreenAuxiliary — чтобы настройки пускали и поверх полноэкранного
        // окна: обычному окну в такое пространство хода нет, и без флага
        // система снова уводила бы человека на другой стол.
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        if let obstacle { moveAside(window, from: obstacle) }
        self.window = window

        present(window)
        onPresent()
    }

    /// Показанное окно WindowServer держит за тем столом, где оно появилось, и
    /// одного `moveToActiveSpace` мало: полноэкранное пространство отпускать
    /// окно не хочет. Снятие с экрана эту привязку сбрасывает — ровно так же
    /// разбирается с чужим столом панель в `DropdownPanel.show(from:)`.
    private func present(_ window: NSWindow) {
        if window.isVisible && !window.isOnActiveSpace { window.orderOut(nil) }
        // Приложение живёт без Dock (`LSUIElement`), и без явной активации
        // окно откроется за спиной у текущей программы. Активируем до показа:
        // неактивному приложению система сначала ищет окну «своё» пространство.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Двигаем окно один раз, при создании: дальше место выбирает человек.
    /// Уходим в ту сторону, где на экране больше свободного места, а если
    /// вбок не влезаем — опускаемся под панель.
    private func moveAside(_ window: NSWindow, from obstacle: NSRect) {
        let gap: CGFloat = 12
        var frame = window.frame
        guard frame.intersects(obstacle.insetBy(dx: -gap, dy: -gap)),
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        let toLeft = obstacle.minX - screen.minX > screen.maxX - obstacle.maxX
        let x = toLeft ? obstacle.minX - gap - frame.width : obstacle.maxX + gap
        if x >= screen.minX, x + frame.width <= screen.maxX {
            frame.origin.x = x
        } else {
            frame.origin.y = max(obstacle.minY - gap - frame.height, screen.minY)
        }
        window.setFrame(frame, display: false)
    }

    // MARK: Жизнь окна

    func windowWillClose(_ notification: Notification) { onDismiss() }

    // Свёрнутое окно для нас всё равно что закрытое: ползунков не видно,
    // и панель поверх чужих окон только мешала бы.
    func windowWillMiniaturize(_ notification: Notification) { onDismiss() }

    func windowDidDeminiaturize(_ notification: Notification) { onPresent() }
}
