import Foundation

public enum ClaudeWeek {
    public static let version = "0.2.0"
    public static let bundleIdentifier = "com.greem4.claudeweek"
    /// Откуда приходят обновления: `владелец/репозиторий` на GitHub. Тот же
    /// репозиторий выпускает образы, поэтому имя одно на проверку версии и на
    /// ссылку «что нового».
    public static let repository = "Greem4/ClaudeWeek"

    /// Журнал изменений — тот же `CHANGELOG.md`, но на GitHub, где он свёрстан
    /// и открывается в браузере. Ссылка идёт на `main`, а не на тег
    /// установленной версии: раздел свежей версии закрывает workflow при
    /// выпуске, поэтому в `main` журнал всегда полнее — там видно и то, что
    /// вышло уже после этой сборки.
    public static var changelogURL: URL {
        URL(string: "https://github.com/\(repository)/blob/main/CHANGELOG.md")!
    }
}
