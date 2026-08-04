import Foundation
import ClaudeWeekCore

// MARK: - Дублёры

/// Отдаёт заранее заготовленные ответы и считает, сколько раз в него сходили.
private actor FakeTransport: UsageTransport {
    private var answers: [(Int, Data)]
    private(set) var calls = 0
    private let failure: Error?

    init(answers: [(Int, String)], failure: Error? = nil) {
        self.answers = answers.map { ($0.0, Data($0.1.utf8)) }
        self.failure = failure
    }

    func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
        calls += 1
        if let failure { throw failure }
        // Последний ответ повторяется: тесту редко нужен ровно один вызов.
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? (0, Data()))
    }

    func callCount() -> Int { calls }
}

private struct FakeCredentials: CredentialsSource {
    var token = "sk-ant-oat01-тест"
    var error: Error?

    func load() throws -> OAuthCredentials {
        if let error { throw error }
        return OAuthCredentials(accessToken: token, expiresAt: nil, subscriptionType: "max")
    }
}

/// Ответ в том виде, в каком его отдаёт api.anthropic.com (проверено 2026-08-04).
/// Половина ключей приходит null — это норма, а не поломка.
private let realResponse = """
{
  "five_hour": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-08-04T20:19:59.357955+00:00",
                "used_dollars": null, "utilization": 41},
  "seven_day": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-08-07T12:00:00.357993+00:00",
                "used_dollars": null, "utilization": 50},
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    {"group": "session", "is_active": false, "kind": "session", "percent": 41,
     "resets_at": "2026-08-04T20:19:59.357955+00:00", "scope": null, "severity": "normal"},
    {"group": "weekly", "is_active": true, "kind": "weekly_all", "percent": 50,
     "resets_at": "2026-08-07T12:00:00.357993+00:00", "scope": null, "severity": "normal"}
  ],
  "member_dashboard_available": false
}
"""

/// Каталог транскриптов со своим индексом и кешем — чтобы тест не трогал
/// настоящие данные пользователя.
private struct TranscriptSandbox {
    let base: URL
    let root: URL
    let indexURL: URL
    let cacheURL: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-week-official-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        indexURL = base.appendingPathComponent("index.json")
        cacheURL = base.appendingPathComponent("cache.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// Одно сообщение Opus заданной условной стоимости: вход $5 за Mtok.
    func write(cost: Double, at timestamp: String) {
        let tokens = Int(cost / 5 * 1_000_000)
        let line = """
        {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(timestamp)",\
        "message":{"model":"claude-opus-5","usage":{"input_tokens":\(tokens),"output_tokens":0}}}
        """
        try? (line + "\n").write(
            to: root.appendingPathComponent("сессия.jsonl"), atomically: true, encoding: .utf8
        )
    }
}

private let testNow = at(2026, 8, 4, 12, 0)

/// Сервер отдаёт момент сброса с микросекундами (`12:00:00.357993`), и мы
/// сохраняем его как есть — округлять чужие данные незачем. Поэтому даты
/// сверяем с допуском в секунду, а не на точное равенство.
private func same(_ t: Harness, _ got: Date?, _ want: Date, _ what: String) {
    guard let got else { return t.fail("\(what): даты нет вовсе") }
    t.close(got.timeIntervalSince(want), 0, what, tolerance: 1)
}

private func provider(
    answers: [(Int, String)] = [(200, realResponse)],
    credentials: FakeCredentials = FakeCredentials(),
    transportFailure: Error? = nil,
    config c: Config = config(),
    now: Date = testNow
) -> (OfficialProvider, FakeTransport) {
    let transport = FakeTransport(answers: answers, failure: transportFailure)
    let provider = OfficialProvider(
        config: c,
        credentials: credentials,
        transport: transport,
        shape: nil,
        clock: { now }
    )
    return (provider, transport)
}

func runOfficialProviderTests(_ t: Harness) async {
    await t.suite("разбор ответа /api/oauth/usage") {
        let (official, _) = provider()
        let usage = try await official.usage(at: testNow)

        t.close(usage.weekPercent, 50, "недельный процент из seven_day")
        same(t, usage.weekResetsAt, at(2026, 8, 7, 16, 0), "resets_at с микросекундами разобран")
        t.close(usage.sessionPercent ?? -1, 41, "пятичасовой лимит тоже разобран")
    }

    await t.suite("запасной путь: seven_day пропал") {
        // Ключ есть, но null — недельная строка должна найтись в limits.
        let onlyLimits = """
        {"seven_day": null, "five_hour": null,
         "limits": [{"kind": "weekly_all", "percent": 73,
                     "resets_at": "2026-08-07T12:00:00.357993+00:00"}]}
        """
        let (official, _) = provider(answers: [(200, onlyLimits)])
        let usage = try await official.usage(at: testNow)
        t.close(usage.weekPercent, 73, "процент взят из limits по kind")
        same(t, usage.weekResetsAt, at(2026, 8, 7, 16, 0), "и момент сброса тоже")
    }

    await t.suite("ответ без недельного лимита") {
        let (official, _) = provider(answers: [(200, #"{"five_hour": {"utilization": 10}}"#)])
        do {
            _ = try await official.usage(at: testNow)
            t.fail("ждали ошибку разбора")
        } catch UsageError.decoding {
            t.check(true, "пропажа недельного процента — явная ошибка, а не ноль")
        }
    }

    await t.suite("коды ответа") {
        for code in [401, 403] {
            let (official, _) = provider(answers: [(code, "")])
            do {
                _ = try await official.usage(at: testNow)
                t.fail("ждали unauthorized на \(code)")
            } catch UsageError.unauthorized {
                t.check(true, "\(code) — нужна авторизация")
            }
        }

        for code in [429, 500, 503] {
            let (official, _) = provider(answers: [(code, "")])
            do {
                _ = try await official.usage(at: testNow)
                t.fail("ждали unavailable на \(code)")
            } catch UsageError.unavailable {
                t.check(true, "\(code) — источник временно недоступен")
            }
        }
    }

    await t.suite("нет кред — нет запроса") {
        let (official, transport) = provider(
            credentials: FakeCredentials(error: UsageError.unauthorized)
        )
        do {
            _ = try await official.usage(at: testNow)
            t.fail("ждали unauthorized")
        } catch UsageError.unauthorized {
            t.equal(await transport.callCount(), 0, "без токена в сеть не ходим")
        }
    }

    await t.suite("троттлинг: не чаще раза в минуту") {
        let (official, transport) = provider()
        _ = try await official.usage(at: testNow)
        _ = try await official.usage(at: testNow.addingTimeInterval(30))
        t.equal(await transport.callCount(), 1, "повтор через 30 с берётся из памяти")

        _ = try await official.usage(at: testNow.addingTimeInterval(61))
        t.equal(await transport.callCount(), 2, "через 61 с идём в сеть заново")
    }

    await t.suite("пауза после неудачи") {
        let (official, transport) = provider(answers: [(500, "")])
        do { _ = try await official.usage(at: testNow) } catch {}
        t.equal(await transport.callCount(), 1, "первая попытка сделана")

        // Минуту после отказа в сеть не лезем.
        do { _ = try await official.usage(at: testNow.addingTimeInterval(30)) } catch {}
        t.equal(await transport.callCount(), 1, "во время паузы запроса нет")

        do { _ = try await official.usage(at: testNow.addingTimeInterval(61)) } catch {}
        t.equal(await transport.callCount(), 2, "после паузы пробуем снова")
    }

    await t.suite("снимок официального источника") {
        let (official, _) = provider()
        let snapshot = try await official.fetch()

        t.close(snapshot.usedPercent, 50, "итог недели")
        t.equal(snapshot.source, .official, "источник официальный")
        t.check(!snapshot.isEstimate, "итог не помечен оценкой")
        t.check(snapshot.shapeIsEstimate, "а форма недели — помечена")
        same(t, snapshot.window.end, at(2026, 8, 7, 16, 0), "конец окна взят из ответа")
        same(t, snapshot.window.start, at(2026, 7, 31, 16, 0), "начало — неделей раньше")
    }

    await t.suite("окно от resets_at") {
        let window = WeekWindow(endingAt: at(2026, 8, 7, 16, 0), config: config())
        t.equal(window.start, at(2026, 7, 31, 16, 0), "начало на семь суток раньше конца")
        t.close(window.duration, 7 * 86_400, "окно длиной в неделю")
        t.equal(window.days.count, 7, "семь суточных слотов")
        t.equal(window.dayIndex(for: at(2026, 8, 4, 12, 0)), 3,
                "вторник до 16:00 — четвёртые сутки окна")
        t.equal(window.dayIndex(for: at(2026, 8, 4, 17, 0)), 4,
                "после 16:00 начинаются пятые")

        // Конфиг говорит одно, сервер — другое; выигрывает сервер.
        t.check(WeekWindow(containing: at(2026, 8, 4, 12, 0), config: config()).end != window.end,
                "окно из конфига и окно из API — разные, и это ожидаемо")
    }

    await t.suite("выбор источника: official падает на local") {
        // Официальный отказывает, локальный не откалиброван — наружу должна
        // уйти причина отказа официального, она информативнее.
        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(error: UsageError.unauthorized),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: nil,
            clock: { testNow }
        )
        do {
            _ = try await resolving.fetch()
            t.fail("ждали ошибку")
        } catch UsageError.unauthorized {
            t.check(true, "в режиме auto наружу идёт причина отказа официального источника")
        } catch UsageError.notCalibrated {
            t.check(true, "или причина отказа локального — обе честные")
        }
    }

    await t.suite("режим local не ходит в сеть") {
        var localOnly = config()
        localOnly.provider = .local
        let transport = FakeTransport(answers: [(200, realResponse)])
        let resolving = ResolvingProvider(
            config: localOnly,
            credentials: FakeCredentials(),
            transport: transport,
            cacheURL: nil,
            clock: { testNow }
        )
        _ = try? await resolving.fetch()
        t.equal(await transport.callCount(), 0, "provider=local отключает сеть целиком")
    }

    await t.suite("округление момента сброса") {
        // Сервер отдаёт то 12:00:00.357, то 11:59:59.9 — один и тот же сброс.
        let late = ISO8601.parse("2026-08-07T12:00:00.357993+00:00")!
        let early = ISO8601.parse("2026-08-07T11:59:59.900000+00:00")!
        t.equal(OfficialUsage.roundToMinute(late), OfficialUsage.roundToMinute(early),
                "секундный дрейф ответа даёт один и тот же момент")
        t.equal(OfficialUsage.roundToMinute(late), at(2026, 8, 7, 16, 0),
                "и это ровные 16:00 по Саратову")
    }

    await t.suite("автокалибровка бюджета по официальному проценту") {
        // Официальный источник сказал 50 %; локально за то же окно насчитано
        // $10 — значит неделя стоит $20, и офлайн-оценка это подхватит.
        let sandbox = TranscriptSandbox()
        defer { sandbox.cleanup() }
        sandbox.write(cost: 10, at: "2026-08-01T10:00:00.000Z")

        let cacheURL = sandbox.cacheURL
        let resolving = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            clock: { testNow }
        )

        let snapshot = try await resolving.fetch()
        t.close(snapshot.usedPercent, 50, "показан официальный процент")
        let budget = Store.loadCache(from: cacheURL)?.weeklyBudget ?? 0
        t.close(budget, 20, "бюджет недели подобран: $10 при 50 %", tolerance: 1e-9)

        // Теперь сеть отказала — оценка должна опереться на подобранный бюджет,
        // а не выдать «не откалибровано».
        let offline = ResolvingProvider(
            config: config(),
            credentials: FakeCredentials(error: UsageError.unauthorized),
            transport: FakeTransport(answers: [(200, realResponse)]),
            cacheURL: cacheURL,
            localRoot: sandbox.root,
            indexURL: sandbox.indexURL,
            clock: { testNow }
        )
        let fallback = try await offline.fetch()
        t.close(fallback.usedPercent, 50, "офлайн-оценка совпала с последним официальным числом")
        t.equal(fallback.source, .local, "источник при этом локальный")
        t.check(fallback.isEstimate, "и честно помечен оценкой")
        same(t, fallback.window.end, at(2026, 8, 7, 16, 0),
             "и окно взято от настоящего сброса, а не от resetHour из конфига")

        // Локальная перезапись кеша не должна стереть момент сброса от сервера.
        t.check(Store.loadCache(from: cacheURL)?.officialWindowEnd != nil,
                "официальный момент сброса пережил локальную запись кеша")
    }

    await t.suite("окно из кеша сдвигается целыми неделями") {
        let cache = CachedUsage(
            usedPercent: 50, byDay: [], windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0), source: .official, fetchedAt: testNow,
            weeklyBudget: 20, officialWindowEnd: at(2026, 8, 7, 16, 0)
        )
        // Три недели офлайна: окно должно доехать до актуального, сохранив час.
        let later = at(2026, 8, 25, 12, 0)
        let window = cache.projectedWindow(at: later, config: config())
        t.check(window?.contains(later) == true, "окно накрывает текущий момент")
        same(t, window?.end, at(2026, 8, 28, 16, 0), "сброс остался в 16:00, сдвинувшись на три недели")

        let withoutOfficial = CachedUsage(
            usedPercent: 50, byDay: [], windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0), source: .local, fetchedAt: testNow
        )
        t.check(withoutOfficial.projectedWindow(at: testNow, config: config()) == nil,
                "без официального момента сброса окно не выдумываем")
    }

    await t.suite("кеш: свежесть по окну") {
        let cache = CachedUsage(
            usedPercent: 50,
            byDay: [10, 20, nil, nil, nil, nil, nil],
            windowStart: at(2026, 7, 31, 16, 0),
            windowEnd: at(2026, 8, 7, 16, 0),
            source: .official,
            fetchedAt: testNow
        )
        t.check(cache.isFresh(at: testNow), "кеш текущей недели годен")
        t.check(!cache.isFresh(at: at(2026, 8, 8, 12, 0)), "кеш прошлой недели негоден")
        t.check(!cache.isFresh(at: at(2026, 7, 30, 12, 0)), "и будущей тоже")

        let snapshot = cache.snapshot(config: config())
        t.close(snapshot.usedPercent, 50, "процент восстановлен")
        t.equal(snapshot.window.end, at(2026, 8, 7, 16, 0), "окно восстановлено как было")
        t.check(!snapshot.isEstimate, "официальный кеш остаётся официальным")
    }

    await t.suite("креды: разбор записи Keychain") {
        let nested: [String: Any] = ["claudeAiOauth": ["accessToken": "sk-ant-oat01-x"]]
        t.equal(KeychainCredentials.findToken(nested), "sk-ant-oat01-x", "токен найден во вложенном объекте")
        t.equal(KeychainCredentials.findToken(["access_token": "sk-x"]), "sk-x", "и в змеиной записи тоже")
        t.check(KeychainCredentials.findToken(["nope": 1]) == nil, "чужая запись не даёт токена")

        // Claude Code пишет миллисекунды; секунды тоже должны разбираться.
        let millis = KeychainCredentials.date(from: NSNumber(value: 1_786_000_000_000))
        let seconds = KeychainCredentials.date(from: NSNumber(value: 1_786_000_000))
        t.equal(millis, seconds, "миллисекунды и секунды дают один момент")
        t.check(KeychainCredentials.date(from: nil) == nil, "нет поля — нет даты")

        let expired = OAuthCredentials(
            accessToken: "x", expiresAt: testNow.addingTimeInterval(-60), subscriptionType: nil
        )
        t.check(expired.isExpired(at: testNow), "истёкший токен виден")
        t.check(!OAuthCredentials(accessToken: "x", expiresAt: nil, subscriptionType: nil)
            .isExpired(at: testNow), "без срока считаем годным")
    }

    await t.suite("разбор меток времени") {
        same(t, ISO8601.parse("2026-08-07T12:00:00.357993+00:00"), at(2026, 8, 7, 16, 0),
             "микросекунды и смещение вместо Z")
        t.equal(ISO8601.parse("2026-08-07T12:00:00Z"), at(2026, 8, 7, 16, 0),
                "без долей секунды")
        t.equal(ISO8601.parse("2026-08-07T12:00:00.000Z"), at(2026, 8, 7, 16, 0),
                "миллисекунды из транскриптов")
        t.check(ISO8601.parse("кривая дата") == nil, "мусор не превращается в дату")
    }
}
