import Foundation

// MARK: - Ответ эндпоинта

/// Разобранный ответ `/api/oauth/usage` — только то, что нужно панели.
/// Полная схема зафиксирована в `docs/API.md`.
public struct OfficialUsage: Sendable, Equatable {
    /// Расход недельного лимита по всем моделям, 0…100.
    public let weekPercent: Double
    public let weekResetsAt: Date
    /// Текущая пятичасовая сессия — второй лимит, в который упираются
    /// на практике. Приходит одной строкой рядом с недельной.
    public let sessionPercent: Double?
    public let sessionResetsAt: Date?

    /// Сессия для панели: без процента или без момента сброса показывать
    /// нечего — «41 %» неизвестно до какого часа не значит ничего.
    public var session: SessionUsage? {
        guard let sessionPercent, let sessionResetsAt else { return nil }
        return SessionUsage(usedPercent: sessionPercent, resetsAt: sessionResetsAt)
    }

    /// Неделя этого числа ещё не закрылась. То же правило, что у сессии, и по
    /// той же причине: после сброса прежний процент не «слегка устарел», а
    /// обнулился — 100 % прошлой недели в новой значат ноль, а не сотню.
    public func isFresh(at now: Date) -> Bool { now < weekResetsAt }

    public init(
        weekPercent: Double,
        weekResetsAt: Date,
        sessionPercent: Double? = nil,
        sessionResetsAt: Date? = nil
    ) {
        self.weekPercent = weekPercent
        self.weekResetsAt = weekResetsAt
        self.sessionPercent = sessionPercent
        self.sessionResetsAt = sessionResetsAt
    }

    /// Момент сброса плавает у сервера на доли секунды в обе стороны:
    /// в одном ответе `12:00:00.357993`, в следующем — `11:59:59.9…`.
    /// Без округления подпись прыгает между «сброс ПТ 16:00» и «15:59», хотя
    /// сброс один и тот же. Сброс — величина минутного разрешения, и полминуты
    /// на недельном окне не значат ничего.
    public static func roundToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }
}

/// Декодер строго под наблюдавшуюся схему, но терпимый к пропаже полей:
/// половина ключей ответа приходит `null` в зависимости от тарифа, и это норма.
struct UsageResponse: Decodable {
    struct Bucket: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// Дублирующее представление тех же лимитов списком. Держим как запасной
    /// путь: если `seven_day` однажды станет `null`, недельная строка ещё
    /// найдётся здесь по `kind`.
    struct Limit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case kind, percent
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Bucket?
    let sevenDay: Bucket?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    static let weeklyKind = "weekly_all"
    static let sessionKind = "session"

    func usage() throws -> OfficialUsage {
        let weekly = limits?.first { $0.kind == UsageResponse.weeklyKind }
        let session = limits?.first { $0.kind == UsageResponse.sessionKind }

        guard let percent = sevenDay?.utilization ?? weekly?.percent else {
            throw UsageError.decoding(Bilingual("в ответе нет недельного процента (seven_day/weekly_all)",
                                                "the reply has no weekly percentage (seven_day/weekly_all)"))
        }
        guard let resetsText = sevenDay?.resetsAt ?? weekly?.resetsAt,
              let resetsAt = ISO8601.parse(resetsText)
        else {
            throw UsageError.decoding(Bilingual("в ответе нет разбираемого resets_at для недели",
                                                "the reply has no parsable resets_at for the week"))
        }

        return OfficialUsage(
            weekPercent: percent,
            weekResetsAt: OfficialUsage.roundToMinute(resetsAt),
            sessionPercent: fiveHour?.utilization ?? session?.percent,
            // Тот же секундный дрейф, что и у недели: без округления обратный
            // отсчёт до конца сессии дёргался бы на минуту туда-сюда.
            sessionResetsAt: (fiveHour?.resetsAt ?? session?.resetsAt)
                .flatMap(ISO8601.parse)
                .map(OfficialUsage.roundToMinute)
        )
    }
}

// MARK: - Транспорт

public protocol UsageTransport: Sendable {
    /// Возвращает код ответа и тело. Ошибки сети бросает.
    func get(url: URL, headers: [String: String]) async throws -> (Int, Data)
}

public struct URLSessionTransport: UsageTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

// MARK: - Провайдер

/// Официальный источник: тот же процент, что показывает `/usage` внутри
/// Claude Code.
///
/// Даёт точное число и точный момент сброса, но не даёт разбивку по суткам —
/// её форму берём из локальных транскриптов и масштабируем к официальному
/// итогу (решение §2.3 плана).
public actor OfficialProvider: UsageProvider {
    nonisolated public let kind: SourceKind = .official

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Не чаще раза в минуту, каким бы коротким ни был `refreshInterval`.
    public static let minimumInterval: TimeInterval = 60
    static let backoffSteps: [TimeInterval] = [60, 120, 240, 480, 900]
    /// Сколько последнее удачное число годится, пока держится пауза после
    /// отказа. Дольше самой длинной паузы держаться за него незачем: расход
    /// за это время меняется, а локальная оценка считается по свежим
    /// транскриптам — пусть `auto` уходит на неё, чем показывать старое число
    /// как сегодняшнее.
    public static let staleLimit: TimeInterval = 15 * 60

    private let config: Config
    private let credentials: CredentialsSource
    private let transport: UsageTransport
    /// Откуда берём форму недели; nil — панель останется без суточных полос.
    private let shape: LocalProvider?
    private let clock: @Sendable () -> Date

    private var lastUsage: OfficialUsage?
    private var lastFetch: Date?
    /// До этого момента в сеть не ходим — держим паузу после ошибки.
    private var retryAfter: Date?
    private var failures = 0

    public init(
        config: Config,
        credentials: CredentialsSource = KeychainCredentials(),
        transport: UsageTransport = URLSessionTransport(),
        shape: LocalProvider? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.credentials = credentials
        self.transport = transport
        self.shape = shape
        self.clock = clock
    }

    public func fetch() async throws -> UsageSnapshot {
        let now = clock()
        let usage = try await usage(at: now)
        let window = WeekWindow(endingAt: usage.weekResetsAt, config: config)
        // Момент наблюдения, а не текущий: во время троттлинга и паузы после
        // отказа отдаётся последнее удачное число, и метить его свежим нельзя —
        // по `fetchedAt` панель называет возраст данных.
        let observedAt = lastFetch ?? now
        // Один обход транскриптов на оба вопроса: и форма недели, и разбивка
        // по моделям выходят из одного расчёта. Разбивки сервер не даёт вовсе
        // (`docs/API.md`), поэтому «чем потрачено» здесь всегда локальное.
        let local = await localUsage(window: window, now: now)

        return UsageSnapshot.make(
            usedPercent: usage.weekPercent,
            cumulativeByDay: shapeByDay(local, total: usage.weekPercent, window: window),
            window: window,
            source: .official,
            fetchedAt: observedAt,
            isEstimate: false,
            shapeIsEstimate: true,
            session: usage.session,
            byModel: local?.byModel ?? []
        )
    }

    /// Свежий процент, с учётом троттлинга и паузы после ошибок.
    public func usage(at now: Date) async throws -> OfficialUsage {
        // Число из памяти годится, только пока не наступил его собственный
        // сброс. После него это не «данные минутной давности», а прошлая
        // неделя: держась за неё, панель показывала исчерпанный лимит ещё
        // четверть часа после обнуления — ровно на длину паузы после отказа.
        let remembered = lastUsage.flatMap { $0.isFresh(at: now) ? $0 : nil }

        if let remembered, let lastFetch,
           now.timeIntervalSince(lastFetch) < OfficialProvider.minimumInterval {
            return remembered
        }
        if let retryAfter, now < retryAfter {
            // Пауза ещё держится: отдаём последнее удачное значение, пока оно
            // не слишком старое. Просроченное — честная ошибка, чтобы
            // вызывающий ушёл на локальную оценку: она хотя бы сегодняшняя.
            if let remembered, let lastFetch,
               now.timeIntervalSince(lastFetch) <= OfficialProvider.staleLimit {
                return remembered
            }
            throw UsageError.unavailable(
                "жду \(Formatting.duration(retryAfter.timeIntervalSince(now))) после неудачи"
            )
        }

        do {
            let usage = try await request(at: now)
            lastUsage = usage
            lastFetch = now
            retryAfter = nil
            failures = 0
            return usage
        } catch {
            note(failure: error, at: now)
            throw error
        }
    }

    private func request(at now: Date) async throws -> OfficialUsage {
        // Креды перечитываем каждый раз: Claude Code обновляет токен сам,
        // и закешированный у нас экземпляр протух бы молча.
        let creds = try credentials.load()
        if creds.isExpired(at: now) {
            Log.debug("токен в Keychain истёк, всё равно пробую — Claude Code мог обновить его только что")
        }

        let (code, body): (Int, Data)
        do {
            (code, body) = try await transport.get(
                url: OfficialProvider.endpoint,
                headers: [
                    "Authorization": "Bearer \(creds.accessToken)",
                    "Content-Type": "application/json",
                    "User-Agent": "ClaudeWeek/\(ClaudeWeek.version)",
                ]
            )
        } catch {
            throw UsageError.network(Bilingual(stringLiteral: error.localizedDescription))
        }

        switch code {
        case 200:
            do {
                return try JSONDecoder().decode(UsageResponse.self, from: body).usage()
            } catch let error as UsageError {
                throw error
            } catch {
                throw UsageError.decoding("\(error)")
            }
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            throw UsageError.unavailable(Bilingual("слишком частые запросы (429)", "too many requests (429)"))
        default:
            throw UsageError.unavailable("HTTP \(code)")
        }
    }

    /// Экспоненциальная пауза 1 → 2 → 4 → 8 → 15 минут.
    private func note(failure: Error, at now: Date) {
        failures += 1
        let step = OfficialProvider.backoffSteps[
            min(failures - 1, OfficialProvider.backoffSteps.count - 1)
        ]
        retryAfter = now.addingTimeInterval(step)
        Log.warn("официальный источник недоступен (\(failure)), следующая попытка через \(Formatting.duration(step))")
    }

    /// Локальный расчёт за то же окно; nil — транскриптов нет или они пусты.
    private func localUsage(window: WeekWindow, now: Date) async -> LocalUsage? {
        guard let shape else { return nil }
        guard let local = try? await shape.scan(window: window, now: now), local.totalCost > 0 else {
            Log.debug("локальной формы нет — панель покажет только итог")
            return nil
        }
        return local
    }

    /// Форма недели: доля каждых суток в локальной стоимости, умноженная на
    /// официальный процент. Итог точный, форма правдоподобная.
    private func shapeByDay(_ local: LocalUsage?, total: Double, window: WeekWindow) -> [Double?] {
        guard let local else { return Array(repeating: nil, count: window.slotCount) }

        var running = 0.0
        return local.costByDay.map { cost in
            guard let cost else { return nil }
            running += cost
            return running / local.totalCost * total
        }
    }
}
