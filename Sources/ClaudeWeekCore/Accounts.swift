import Foundation

/// Разложенные пути одного аккаунта: где его транскрипты и где файлы, которыми
/// ClaudeWeek ведёт по нему счёт.
///
/// Состояние аккаунтов лежит порознь намеренно. Общий `cache.json` позволил бы
/// последнему обновлению одного аккаунта стереть снимок другого, а общий
/// `state.json` — отдать отсечку счёта не тому лимиту. Первый аккаунт при этом
/// сохраняет прежние имена файлов: у него уже есть накопленный счёт, и переезд
/// на новое имя обнулил бы его на ровном месте.
public struct AccountLocation: Sendable, Equatable {
    public let account: UsageAccount
    /// Конфиг-дом Claude Code — то же, что уходит в `CLAUDE_CONFIG_DIR`.
    public let home: URL

    public init(account: UsageAccount, home: URL) {
        self.account = account
        self.home = home
    }

    public init(account: UsageAccount, config: Config) {
        self.init(account: account, home: AccountLocation.expand(config.accounts.home(account)))
    }

    /// Каталог транскриптов — то, по чему считает `LocalProvider`.
    public var projectsRoot: URL {
        home.appendingPathComponent("projects", isDirectory: true)
    }

    /// Запасной путь к кредам: на части установок Claude Code кладёт их файлом,
    /// а не в Keychain. Файл лежит в самом доме, поэтому у каждого аккаунта он
    /// свой без всяких настроек.
    public var credentialsFileURL: URL {
        home.appendingPathComponent(".credentials.json")
    }

    /// Дом существует. Единственный признак, по которому решается, показывать
    /// ли переключатель: заводить для этого отдельный флаг в конфиге значило бы
    /// держать вторую копию того же факта, и она бы разошлась.
    public var exists: Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    private var filePrefix: String {
        switch account {
        case .primary: ""
        case .secondary: "secondary-"
        }
    }

    private func stateFile(_ name: String) -> URL {
        Store.directory.appendingPathComponent(filePrefix + name)
    }

    public var cacheURL: URL { stateFile("cache.json") }
    public var alertsURL: URL { stateFile("alerts.json") }
    public var countingStateURL: URL { stateFile("state.json") }
    public var indexURL: URL { stateFile("index.json") }

    /// Дом, который Claude Code берёт сам, когда `CLAUDE_CONFIG_DIR` не задан.
    /// Значим не только как путь: спрашивать про него надо именно без
    /// переменной — см. `AccountDirectory.read(home:)`.
    public static var defaultHome: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Дом стандартный — тот, что достаётся установке Claude Code из коробки.
    public var isDefaultHome: Bool {
        home.standardizedFileURL.path == AccountLocation.defaultHome.standardizedFileURL.path
    }

    /// `~` в пути конфига раскрываем сами: путь пишет человек, а `URL` тильду
    /// не понимает и молча заводит каталог с именем «~».
    public static func expand(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }
}

/// Кто вошёл в этот конфиг-дом. Отвечает сам Claude Code — `claude auth status`
/// печатает JSON, и другого источника, знающего про дом, у нас нет: по записи
/// Keychain дом не определить, а по транскриптам аккаунт не различить вовсе.
public struct AccountStatus: Sendable, Equatable {
    public let loggedIn: Bool
    public let email: String?
    public let organizationId: String?
    public let subscriptionType: String?

    public init(
        loggedIn: Bool,
        email: String? = nil,
        organizationId: String? = nil,
        subscriptionType: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.email = email
        self.organizationId = organizationId
        self.subscriptionType = subscriptionType
    }

    public static let signedOut = AccountStatus(loggedIn: false)

    /// Чем аккаунт подписывают в интерфейсе: адрес короче и понятнее UUID,
    /// а при его отсутствии — хотя бы тариф.
    public func title(fallback: String) -> String {
        if let email, !email.isEmpty { return email }
        if let subscriptionType, !subscriptionType.isEmpty { return subscriptionType }
        return fallback
    }
}

/// Спрашивает Claude Code, кто вошёл в указанный дом.
///
/// Запускается процесс, поэтому ответ кешируется: панель обновляется раз в
/// минуту, а вход и выход случаются раз в месяц. Кеш сбрасывает тот, кто знает
/// повод — окно настроек по кнопке проверки и переключение аккаунта.
public actor AccountDirectory {
    public static let shared = AccountDirectory()

    private var cache: [URL: AccountStatus] = [:]

    public init() {}

    public func status(of location: AccountLocation) async -> AccountStatus {
        if let known = cache[location.home] { return known }
        let status = AccountDirectory.read(home: location.home)
        cache[location.home] = status
        return status
    }

    public func forget() {
        cache.removeAll()
    }

    /// Ищем исполняемый файл там же, куда его кладёт установщик Claude Code, и
    /// только потом в PATH: у приложения из Dock окружение обрезанное, и на
    /// PATH там рассчитывать нельзя.
    static func executable() -> URL? {
        var candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func read(home: URL) -> AccountStatus {
        guard let executable = executable() else {
            Log.debug("не нашёл исполняемый файл claude — состояние аккаунта неизвестно")
            return .signedOut
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status"]
        var environment = ProcessInfo.processInfo.environment
        // Переменную ставим только для нестандартного дома, и это не
        // придирка. `CLAUDE_CONFIG_DIR=~/.claude` — тот же самый путь, что
        // берётся по умолчанию, — даёт `loggedIn: false`, тогда как без
        // переменной тот же дом отвечает `true` (проверено на 2.1.251).
        // Значит ячейку учётных данных выбирает не путь сам по себе, а факт
        // установки переменной. Ставя её всегда, мы объявляли бы невошедшим
        // аккаунт, в котором человек сидит прямо сейчас.
        //
        // Унаследованное значение при этом обязательно убрать: приложение
        // могли запустить из оболочки, где оно уже выставлено, — например из
        // сеанса под вторым аккаунтом.
        if AccountLocation(account: .primary, home: home).isDefaultHome {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = home.path
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.debug("claude auth status не запустился: \(error.localizedDescription)")
            return .signedOut
        }

        // Панель обновляется в фоне; повисший на чём-нибудь процесс не должен
        // забирать её с собой.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        // Код возврата не проверяем: у невошедшего аккаунта он единица, но
        // ответ при этом осмысленный и разбирается тем же путём. Судим по
        // содержимому, а не по коду.
        return parse(output)
    }

    /// Форма ответа — не публичный контракт, поэтому недостающие поля здесь
    /// норма, а не ошибка: без адреса аккаунт подпишется тарифом, без тарифа —
    /// номером, и переключатель продолжит работать.
    public static func parse(_ data: Data) -> AccountStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .signedOut
        }
        guard root["loggedIn"] as? Bool == true else { return .signedOut }
        return AccountStatus(
            loggedIn: true,
            email: root["email"] as? String,
            organizationId: root["orgId"] as? String,
            subscriptionType: root["subscriptionType"] as? String
        )
    }
}

public extension ResolvingProvider {
    /// Провайдер для одного аккаунта: свои транскрипты, свои файлы счёта, свои
    /// креды.
    ///
    /// Аккаунту без входа даём `SignedOutCredentials`, а не `nil`: `nil` здесь
    /// значит «Keychain по умолчанию», и второй дом молча показал бы цифры
    /// первого.
    static func forAccount(
        _ account: UsageAccount,
        config: Config,
        status: AccountStatus
    ) -> ResolvingProvider {
        let location = AccountLocation(account: account, config: config)
        let credentials = credentials(for: account, config: config, status: status)

        return ResolvingProvider(
            config: config,
            credentials: credentials,
            cacheURL: location.cacheURL,
            localRoot: location.projectsRoot,
            indexURL: location.indexURL,
            stateURL: location.countingStateURL,
            alertsURL: location.alertsURL
        )
    }

    /// Откуда берётся токен аккаунта. Отдельно от фабрики, потому что тем же
    /// ответом подписывается отсечка счёта: спрашивать «чей это аккаунт» надо
    /// у того же источника, из которого потом читают токен.
    static func credentials(
        for account: UsageAccount,
        config: Config,
        status: AccountStatus
    ) -> CredentialsSource {
        let location = AccountLocation(account: account, config: config)
        switch account {
        case .primary:
            // Первый аккаунт живёт в записи с известным именем — той самой,
            // которую Claude Code завёл при установке.
            return KeychainCredentials(fileURL: location.credentialsFileURL)
        case .secondary:
            return status.organizationId.map {
                ResolvedKeychainCredentials(
                    organizationId: $0,
                    fileURL: location.credentialsFileURL
                ) as CredentialsSource
            } ?? SignedOutCredentials()
        }
    }
}
