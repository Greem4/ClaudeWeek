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
            guard config != oldValue else { return }
            apply(config)
        }
    }

    /// Токен из поля ввода. В конфиг не попадает никогда — только в Keychain.
    var tokenField: String = ""
    var tokenSaved: Bool = ManualToken.exists
    /// Итог последней проверки токена: текст и удача/неудача.
    var checkResult: (text: String, ok: Bool)?
    var isChecking = false

    private let apply: (Config) -> Void
    private let check: (Config) async -> (String, Bool)

    init(
        config: Config,
        apply: @escaping (Config) -> Void,
        check: @escaping (Config) async -> (String, Bool)
    ) {
        self.config = config
        self.apply = apply
        self.check = check
    }

    func saveToken() {
        tokenSaved = ManualToken.save(tokenField)
        tokenField = ""
        checkResult = tokenSaved
            ? ("токен сохранён в Keychain", true)
            : ("не смог сохранить токен", false)
        // Сам факт сохранения ничего не меняет в конфиге, но провайдер надо
        // пересоздать: он держит источник кредов с момента создания.
        apply(config)
    }

    func deleteToken() {
        ManualToken.delete()
        tokenSaved = false
        checkResult = ("токен удалён", true)
        apply(config)
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

    /// `obstacle` — рамка живой панели: новое окно ставим так, чтобы её
    /// не накрыть, иначе предпросмотр придётся откапывать мышью.
    func show(avoiding obstacle: NSRect? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onPresent()
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки ClaudeWeek"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ClaudeWeekSettings")
        if let obstacle { moveAside(window, from: obstacle) }
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // Приложение живёт без Dock (`LSUIElement`), и без явной активации
        // окно откроется за спиной у текущей программы.
        NSApp.activate(ignoringOtherApps: true)
        onPresent()
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
