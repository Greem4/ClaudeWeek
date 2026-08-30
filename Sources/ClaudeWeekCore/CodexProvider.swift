import Darwin
import Foundation

// MARK: - Ответ app-server

/// Одно окно лимита Codex. Поля повторяют стабильный JSON-RPC контракт
/// `account/rateLimits/read`; дата уже переведена из Unix timestamp.
public struct CodexRateLimitWindow: Decodable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }

    public init(usedPercent: Double, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usedPercent: try c.decode(Double.self, forKey: .usedPercent),
            windowDurationMinutes: try c.decodeIfPresent(Int.self, forKey: .windowDurationMinutes),
            resetsAt: try c.decodeIfPresent(TimeInterval.self, forKey: .resetsAt).map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }
}

/// Пара лимитов одного metered bucket: короткий `primary` и длинный
/// `secondary`. На некоторых тарифах одного из них может не быть.
public struct CodexRateLimitBucket: Decodable, Sendable, Equatable {
    public let limitId: String?
    public let limitName: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public init(
        limitId: String? = nil,
        limitName: String? = nil,
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }
}

/// Ответ метода лимитов. `rateLimits` оставлен сервером для совместимости,
/// словарь — новый многобакетный вид; провайдер понимает оба.
public struct CodexRateLimits: Decodable, Sendable, Equatable {
    public let rateLimits: CodexRateLimitBucket?
    public let rateLimitsByLimitId: [String: CodexRateLimitBucket]?

    public init(
        rateLimits: CodexRateLimitBucket?,
        rateLimitsByLimitId: [String: CodexRateLimitBucket]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }
}

public struct CodexDailyUsage: Decodable, Sendable, Equatable {
    public let startDate: String
    public let tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

/// Токенная статистика — отдельный официальный метод. Для панели сейчас
/// важны дневные бакеты: по ним восстанавливается форма недельного расхода.
public struct CodexTokenUsage: Decodable, Sendable, Equatable {
    public let dailyUsageBuckets: [CodexDailyUsage]?

    public init(dailyUsageBuckets: [CodexDailyUsage]?) {
        self.dailyUsageBuckets = dailyUsageBuckets
    }
}

public struct CodexAccountUsage: Sendable, Equatable {
    public let limits: CodexRateLimits
    public let tokens: CodexTokenUsage?

    public init(limits: CodexRateLimits, tokens: CodexTokenUsage? = nil) {
        self.limits = limits
        self.tokens = tokens
    }
}

public protocol CodexUsageTransport: Sendable {
    func fetch() async throws -> CodexAccountUsage
}

// MARK: - Транспорт app-server

/// Запускает официальный `codex app-server` на один короткий обмен. Сам
/// app-server читает и обновляет авторизацию Codex; ClaudeWeek токены не
/// открывает, не копирует и не сохраняет.
public struct CodexAppServerTransport: CodexUsageTransport {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 20) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func fetch() async throws -> CodexAccountUsage {
        let executable = try executableURL ?? Self.findExecutable()
        return try AppServerCall(executable: executable, timeout: timeout).run()
    }

    /// LaunchAgent получает короткий системный PATH, поэтому одного `which`
    /// недостаточно. Сначала уважаем явный путь, затем PATH и обычные места
    /// установки CLI на macOS.
    private static func findExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var candidates: [URL] = []

        if let explicit = environment["CODEX_EXECUTABLE"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
            })
        }
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".npm-global/bin/codex"),
            home.appendingPathComponent("Library/pnpm/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
        ])

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found.resolvingSymlinksInPath()
        }
        throw UsageError.unavailable(Bilingual(
            "не найден Codex CLI; установите Codex и войдите в аккаунт",
            "Codex CLI was not found; install Codex and sign in"
        ))
    }
}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}

private struct RPCEnvelope<Result: Decodable>: Decodable {
    let result: Result?
    let error: RPCError?
}

/// Синхронный обмен намеренно живёт внутри фонового актора провайдера. `poll`
/// даёт настоящий таймаут на чтение stdout, не оставляя зависший дочерний
/// процесс и не блокируя главный актор приложения.
private struct AppServerCall {
    let executable: URL
    let timeout: TimeInterval

    func run() throws -> CodexAccountUsage {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        // В stderr app-server пишет диагностику окружения. Она не является
        // протоколом и не должна ни попасть в лог с чужими путями, ни забить
        // непрочитанный pipe.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            Log.debug("Codex app-server запущен, pid=\(process.processIdentifier)")
        } catch {
            throw UsageError.unavailable(Bilingual(
                "не запустил Codex CLI: \(error.localizedDescription)",
                "could not start Codex CLI: \(error.localizedDescription)"
            ))
        }

        defer {
            Log.debug("закрываю Codex app-server, pid=\(process.processIdentifier)")
            try? input.fileHandleForWriting.close()
            stop(process)
            Log.debug("обмен с Codex app-server завершён")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var reader = JSONLineReader(handle: output.fileHandleForReading)

        try write([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "claude_week",
                    "title": "ClaudeWeek",
                    "version": ClaudeWeek.version,
                ],
            ],
        ], to: input.fileHandleForWriting)
        Log.debug("Codex app-server: жду initialize")

        // Инициализацию надо подтвердить только после ответа: при закрытии
        // stdin раньше этого app-server штатно завершится, не начав запросы.
        let initialization: RPCEnvelope<InitializationResult> = try response(
            id: 0, from: &reader, deadline: deadline
        )
        if let error = initialization.error { throw rpcUsageError(error) }
        guard initialization.result != nil else {
            throw UsageError.decoding(Bilingual(
                "Codex app-server не подтвердил initialize",
                "Codex app-server did not acknowledge initialize"
            ))
        }
        Log.debug("Codex app-server: initialize подтверждён")

        try write(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try write(["method": "account/rateLimits/read", "id": 1], to: input.fileHandleForWriting)
        try write(["method": "account/usage/read", "id": 2], to: input.fileHandleForWriting)
        Log.debug("Codex app-server: запросил лимиты и дневную статистику")

        var limits: CodexRateLimits?
        var tokens: CodexTokenUsage?
        var receivedUsageReply = false

        do {
            while limits == nil || !receivedUsageReply {
                guard Date() < deadline else { throw JSONLineReader.Failure.timedOut }
                let line = try reader.nextLine(deadline: deadline)
                guard let id = responseID(in: line) else { continue }
                switch id {
                case 1:
                    let envelope = try JSONDecoder().decode(RPCEnvelope<CodexRateLimits>.self, from: line)
                    if let error = envelope.error { throw rpcUsageError(error) }
                    guard let value = envelope.result else {
                        throw UsageError.decoding(Bilingual(
                            "Codex не вернул rateLimits",
                            "Codex did not return rateLimits"
                        ))
                    }
                    limits = value
                case 2:
                    let envelope = try JSONDecoder().decode(RPCEnvelope<CodexTokenUsage>.self, from: line)
                    // Старый CLI может ещё не знать этот вспомогательный
                    // метод. Лимиты от этого не пропадают — только дневная
                    // форма останется пустой.
                    tokens = envelope.error == nil ? envelope.result : nil
                    receivedUsageReply = true
                default:
                    continue
                }
            }
        } catch JSONLineReader.Failure.timedOut where limits != nil {
            // Токенная статистика необязательна. Не прячем уже полученные
            // точные лимиты из-за того, что второй метод задержался.
        }

        guard let limits else {
            throw UsageError.decoding(Bilingual(
                "Codex не вернул лимиты",
                "Codex did not return usage limits"
            ))
        }
        return CodexAccountUsage(limits: limits, tokens: tokens)
    }

    private func response<Result: Decodable>(
        id: Int,
        from reader: inout JSONLineReader,
        deadline: Date
    ) throws -> RPCEnvelope<Result> {
        while true {
            guard Date() < deadline else { throw JSONLineReader.Failure.timedOut }
            let line = try reader.nextLine(deadline: deadline)
            guard responseID(in: line) == id else { continue }
            return try JSONDecoder().decode(RPCEnvelope<Result>.self, from: line)
        }
    }

    private func responseID(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["id"] as? NSNumber
        else { return nil }
        return number.intValue
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    /// Закрытый stdin обычно завершает app-server сам. Если он застрял в
    /// старте или сетевом запросе, SIGTERM на некоторых версиях CLI тоже
    /// остаётся без ответа; бесконечный `waitUntilExit` тогда вешал и CLI, и
    /// обновление панели. Даём штатному выходу секунду и только затем убиваем
    /// именно запущенный нами дочерний процесс.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        // `Process` сам пожинает дочерний процесс своим source. Здесь ждать
        // синхронно нельзя: именно `waitUntilExit` зависал на app-server,
        // застрявшем в старте, даже после SIGKILL в ограниченном окружении.
    }

    private func rpcUsageError(_ error: RPCError) -> UsageError {
        let lower = error.message.lowercased()
        if lower.contains("authentication") || lower.contains("sign in") || lower.contains("login") {
            return .unavailable(Bilingual(
                "нужно войти в аккаунт через Codex CLI",
                "sign in through Codex CLI first"
            ))
        }
        return .unavailable(Bilingual(
            "Codex app-server: \(error.message)",
            "Codex app-server: \(error.message)"
        ))
    }
}

private struct InitializationResult: Decodable {
    let userAgent: String
}

private struct JSONLineReader {
    enum Failure: Error {
        case timedOut
        case closed
        case tooLarge
        case system(Int32)
    }

    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    mutating func nextLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timedOut }
            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let milliseconds = Int32(min(max(remaining * 1_000, 1), Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result == 0 { throw Failure.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw Failure.system(errno)
            }

            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.system(errno)
            }
            guard count > 0 else {
                throw Failure.closed
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4 * 1_024 * 1_024 else { throw Failure.tooLarge }
        }
    }
}

// MARK: - Провайдер

public actor CodexProvider: UsageProvider {
    nonisolated public let kind: SourceKind = .codex

    public static let minimumInterval: TimeInterval = 60
    public static let staleLimit: TimeInterval = 15 * 60
    private static let backoffSteps: [TimeInterval] = [60, 120, 240, 480, 900]

    private let config: Config
    private let transport: CodexUsageTransport
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date

    private var lastUsage: CodexAccountUsage?
    private var lastFetch: Date?
    private var retryAfter: Date?
    private var failures = 0

    public init(
        config: Config,
        transport: CodexUsageTransport = CodexAppServerTransport(),
        cacheURL: URL? = Store.codexCacheURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.cacheURL = cacheURL
        self.clock = clock
    }

    public func fetch() async throws -> UsageSnapshot {
        let now = clock()
        let account = try await usage(at: now)
        let selected = try selectLimits(account.limits, at: now)
        let window = WeekWindow(endingAt: selected.week.resetsAt, config: config)
        let observedAt = lastFetch ?? now

        let snapshot = UsageSnapshot.make(
            usedPercent: selected.week.usedPercent,
            cumulativeByDay: cumulativeByDay(
                account.tokens?.dailyUsageBuckets,
                totalPercent: selected.week.usedPercent,
                window: window,
                now: now
            ),
            window: window,
            source: .codex,
            fetchedAt: observedAt,
            isEstimate: false,
            shapeIsEstimate: true,
            session: selected.session.map {
                SessionUsage(
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt,
                    windowDurationMinutes: $0.windowDurationMinutes ?? 5 * 60
                )
            }
        )
        save(snapshot)
        return snapshot
    }

    public func usage(at now: Date) async throws -> CodexAccountUsage {
        let remembered = lastUsage.flatMap { usage in
            (try? selectLimits(usage.limits, at: now)) != nil ? usage : nil
        }
        if let remembered, let lastFetch,
           now.timeIntervalSince(lastFetch) < CodexProvider.minimumInterval {
            return remembered
        }
        if let retryAfter, now < retryAfter {
            if let remembered, let lastFetch,
               now.timeIntervalSince(lastFetch) <= CodexProvider.staleLimit {
                return remembered
            }
            throw UsageError.unavailable(Bilingual(
                "жду \(Formatting.duration(retryAfter.timeIntervalSince(now))) после ошибки Codex",
                "waiting \(Formatting.duration(retryAfter.timeIntervalSince(now), lang: .en)) after a Codex error"
            ))
        }

        do {
            let usage = try await transport.fetch()
            _ = try selectLimits(usage.limits, at: now)
            lastUsage = usage
            lastFetch = now
            retryAfter = nil
            failures = 0
            return usage
        } catch {
            failures += 1
            let step = Self.backoffSteps[min(failures - 1, Self.backoffSteps.count - 1)]
            retryAfter = now.addingTimeInterval(step)
            Log.warn("Codex недоступен (\(error)), следующая попытка через \(Formatting.duration(step))")
            throw error
        }
    }

    private struct ActiveWindow {
        let usedPercent: Double
        let windowDurationMinutes: Int?
        let resetsAt: Date
    }

    private struct SelectedLimits {
        let week: ActiveWindow
        let session: ActiveWindow?
    }

    /// В многобакетном ответе только ключ `codex` описывает общий тариф.
    /// Модельные bucket рядом с ним нельзя выдавать за лимит аккаунта. Старый
    /// одиночный вид используем лишь как совместимый запасной вариант.
    private func selectLimits(_ result: CodexRateLimits, at now: Date) throws -> SelectedLimits {
        let preferred = result.rateLimitsByLimitId?["codex"]
            ?? result.rateLimitsByLimitId?.values.first { $0.limitId == "codex" }
            ?? result.rateLimits
        let weekLength = 6 * 24 * 60
        let secondary = active(preferred?.secondary, at: now)
        let primary = active(preferred?.primary, at: now)
        let weeklyPrimary = primary.flatMap {
            ($0.windowDurationMinutes ?? 0) >= weekLength ? $0 : nil
        }
        let weekly = [secondary, weeklyPrimary]
            .compactMap { $0 }
            .max {
                ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0)
            }
        guard let week = weekly else {
            throw UsageError.decoding(Bilingual(
                "Codex не сообщил действующий недельный лимит",
                "Codex did not report an active weekly limit"
            ))
        }

        let session: CodexRateLimitWindow?
        if let primary,
           (primary.windowDurationMinutes ?? 0) < weekLength,
           primary.resetsAt != week.resetsAt {
            session = preferred?.primary
        } else {
            session = nil
        }
        return SelectedLimits(week: normalized(week), session: active(session, at: now).map(normalized))
    }

    private func active(_ window: CodexRateLimitWindow?, at now: Date) -> ActiveWindow? {
        guard let window, let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        return ActiveWindow(
            usedPercent: window.usedPercent,
            windowDurationMinutes: window.windowDurationMinutes,
            resetsAt: resetsAt
        )
    }

    private func normalized(_ window: ActiveWindow) -> ActiveWindow {
        ActiveWindow(
            usedPercent: min(max(window.usedPercent, 0), 100),
            windowDurationMinutes: window.windowDurationMinutes,
            resetsAt: OfficialUsage.roundToMinute(window.resetsAt)
        )
    }

    /// Зона биллинга OpenAI: сутки токенной статистики (`startDate` бакета)
    /// нарезаны по её полуночи, а не по местной и не по UTC. Проверено на
    /// живом ответе — обмен в 05:53 UTC попал в бакет предыдущего дня, что
    /// сходится только с тихоокеанским временем.
    private static let codexBillingZone = TimeZone(identifier: "America/Los_Angeles")

    /// Дневные токены задают только форму: точный недельный процент остаётся
    /// знаменателем сервера.
    ///
    /// `startDate` бакета — календарный день тихоокеанской зоны, а окно живёт
    /// в зоне конфига, поэтому бакет раскладывается по суткам окна по
    /// настоящему перекрытию во времени, а не сопоставлением дат. Иначе в
    /// первые местные сутки недельного окна единственный бакет уезжает за его
    /// левую границу, `total` выходит нулевым, и дневная форма пропадает
    /// целиком — хотя точный расход недели сервер уже сообщил.
    private func cumulativeByDay(
        _ buckets: [CodexDailyUsage]?,
        totalPercent: Double,
        window: WeekWindow,
        now: Date
    ) -> [Double?] {
        guard let buckets, !buckets.isEmpty else {
            return Array(repeating: nil, count: window.slotCount)
        }

        var billing = Calendar(identifier: .gregorian)
        if let zone = CodexProvider.codexBillingZone { billing.timeZone = zone }

        // Настоящие интервалы бакетов: [полночь дня биллинга, +сутки).
        // Календарный шаг, а не «+86400», — на переводе часов сутки короче
        // или длиннее, и знаменатель доли должен это учитывать.
        let spans: [(start: Date, end: Date, tokens: Double)] = buckets.compactMap { bucket in
            guard let day = calendarDate(bucket.startDate, calendar: billing) else { return nil }
            let start = billing.startOfDay(for: day)
            guard let end = billing.date(byAdding: .day, value: 1, to: start), end > start else { return nil }
            return (start, end, Double(max(bucket.tokens, 0)))
        }

        let amounts: [Double?] = window.days.map { day in
            guard day.start < now else { return nil }
            return spans.reduce(0.0) { sum, span in
                let lo = max(span.start, day.start)
                let hi = min(span.end, day.end)
                guard hi > lo else { return sum }
                return sum + span.tokens * hi.timeIntervalSince(lo) / span.end.timeIntervalSince(span.start)
            }
        }

        let total = amounts.compactMap { $0 }.reduce(0, +)
        guard total > 0 else {
            // Бакеты есть, но ни один не перекрыл прошедшую часть окна
            // (первые сутки недели, редкий сдвиг зоны). Точный недельный
            // процент известен — относим его к последним прошедшим суткам,
            // а не прячем весь расход за прочерками.
            guard totalPercent > 0, let last = amounts.lastIndex(where: { $0 != nil }) else {
                return Array(repeating: nil, count: window.slotCount)
            }
            return amounts.indices.map { $0 == last ? totalPercent : nil }
        }

        var running = 0.0
        return amounts.map { value in
            guard let value else { return nil }
            running += value
            return running / total * totalPercent
        }
    }

    private func calendarDate(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func save(_ snapshot: UsageSnapshot) {
        guard let cacheURL else { return }
        let cache = CachedUsage(
            usedPercent: snapshot.usedPercent,
            byDay: snapshot.byDay.map(\.usedPercent),
            windowStart: snapshot.window.start,
            windowEnd: snapshot.window.end,
            source: .codex,
            fetchedAt: snapshot.fetchedAt,
            officialWindowEnd: snapshot.window.end,
            session: snapshot.session
        )
        do {
            try Store.saveCache(cache, to: cacheURL)
        } catch {
            Log.warn("не сохранил кеш Codex: \(error)")
        }
    }
}
