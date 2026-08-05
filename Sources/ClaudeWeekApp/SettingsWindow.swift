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
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки ClaudeWeek"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClaudeWeekSettings")
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // Приложение живёт без Dock (`LSUIElement`), и без явной активации
        // окно откроется за спиной у текущей программы.
        NSApp.activate(ignoringOtherApps: true)
    }
}
