import AppKit
import ClaudeWeekCore

/// Автозапуск при входе в систему — через тот же launchd-агент, что пишет
/// `scripts/install.sh`: label, путь плиста и файл лога совпадают до буквы.
/// Заводить рядом второй механизм (SMAppService) нельзя: сработали бы оба, и
/// в строке меню оказалось бы две иконки.
///
/// Ни `bootstrap`, ни `bootout` здесь нет намеренно. Агента из
/// ~/Library/LaunchAgents launchd читает сам при входе в систему, и для
/// «стартовать со следующего входа» довольно наличия файла. Загружать его
/// немедленно нельзя — `RunAtLoad` поднял бы вторую копию поверх работающей;
/// выгружать тоже: `bootout` погасил бы процесс, из которого только что сняли
/// галочку. Поэтому включение и выключение — это ровно запись и удаление
/// файла, а действовать они начинают со следующего входа.
enum LoginItem {
    /// Тот же, что в install.sh и uninstall.sh: три места пишут одного агента,
    /// и разойтись им нельзя — иначе снос старого перестанет его находить.
    /// Скрипты держат эту строку у себя, здесь она берётся из идентификатора
    /// бандла — они совпадают, и одно место правки лучше двух.
    static let label = ClaudeWeek.bundleIdentifier

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Тот же файл, куда пишет агент установщика: логи одной программы должны
    /// лежать в одном месте, кто бы её ни запустил.
    private static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/ClaudeWeek.log")
    }

    /// Автозапуск настраивается только у собранного бандла. У `swift run`
    /// исполняемый файл лежит в .build и живёт до следующей сборки —
    /// прописывать такой путь в launchd незачем.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    /// Плист переписывается целиком каждый раз: приложение могли перенести, и
    /// вчерашний путь в агенте поднимал бы копию, которой уже нет.
    private static func enable() {
        guard let executable = Bundle.main.executableURL?.path else {
            Log.warn("не нашёл исполняемый файл, автозапуск не включён")
            return
        }

        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardErrorPath": logURL.path,
            "StandardOutPath": logURL.path,
        ]

        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: agent, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            Log.info("автозапуск включён: \(plistURL.path)")
        } catch {
            Log.warn("не включил автозапуск: \(error)")
        }
    }

    private static func disable() {
        guard isEnabled else { return }
        do {
            try FileManager.default.removeItem(at: plistURL)
            Log.info("автозапуск выключен")
        } catch {
            Log.warn("не выключил автозапуск: \(error)")
        }
    }
}
